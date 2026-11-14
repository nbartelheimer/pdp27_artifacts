#include <assert.h>
#include <mpi.h>
#include <rdma/fabric.h>
#include <rdma/fi_cm.h>
#include <rdma/fi_endpoint.h>
#include <rdma/fi_rma.h>
#include <rdma/fi_tagged.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mpiext_persistent_c.h"
#include "ompi/communicator/communicator.h"
#include "ompi/mpi/c/bindings.h"
#include "ompi/mpiext/mpiext.h"
#include "ompi_config.h"
#include "opal/runtime/opal_progress.h"

#define OMPI_ERROR -1
#define OMPI_SUCCESS 0

// #define DEBUG
#ifdef DEBUG
#define OPT_PERSISTENT_INFO(fmt, ...)                                  \
	fprintf(stdout, "[OPT PERSISTENT INFO] %s:%d:%s(): " fmt "\n", \
		__FILE__, __LINE__, __func__, ##__VA_ARGS__);          \
	fflush(stdout)
#else
#define OPT_PERSISTENT_INFO(fmt, ...)
#endif

#define OPT_PERSISTENT_ERR(fmt, ...)                                    \
	fprintf(stderr, "[OPT PERSISTENT ERROR] %s:%d:%s(): " fmt "\n", \
		__FILE__, __LINE__, __func__, ##__VA_ARGS__)

#define READY_TO_RECEIVE_FLAG 98
#define TRANSMISSION_COMPLETE_FLAG 99

#define PERSISTENT_LIKELY(x) __builtin_expect(!!(x), 1)
#define PERSISTENT_UNLIKELY(x) __builtin_expect(!!(x), 0)

#define MPIEXT_PERSISTENT_ADDR_KEY "OPT_PERSISTENT_ADDR"
#define PERSISTENT_ALWAYS_INLINE __attribute__((always_inline))

#define MPIEXT_PERSISTENT_DEFAULT_COMP 64
#define DEFAULT_REQUEST_STORE_SIZE UINT32_C(512)
#define PERSISTENT_EAGER_MAX 4096

/* Setup remains on the application's MPI channel. All peers must use this
 * wire format; the marker also rejects old, direction-less setup records. */
#define PERSISTENT_SETUP_WORDS 10
#define PERSISTENT_SETUP_MAGIC UINT64_C(0x5052534953540002)

/* Fit within verbs' 32-bit remote CQ data. Low nine bits address 512 requests.
 */
#define PERSISTENT_CQ_INDEX_MASK (DEFAULT_REQUEST_STORE_SIZE - 1)
#define PERSISTENT_CQ_SLOT UINT32_C(512)
#define PERSISTENT_CQ_CREDIT UINT32_C(1024)

static bool buffered_progress_registered;
static int mpiext_persistent_buffered_progress(void);

typedef enum mpiext_persistent_request_init_state {
	CHECK_FOR_REMOTE_INFO = 1,
	READY
} mpiext_persistent_request_init_state_t;

typedef enum mpiext_persistent_op_type {
	PERSISTENT_SEND = 1,
	PERSISTENT_RECV,
	OP_INVALID
} mpiext_persistent_op_type_t;

typedef enum request_store_state {
	REQ_ACTIVE = 1,
	REQ_FREE
} request_store_state_t;

typedef struct persistent_setup_record {
	uint64_t words[PERSISTENT_SETUP_WORDS];
	struct persistent_setup_record *next;
} persistent_setup_record_t;

typedef struct persistent_setup_block {
	persistent_setup_record_t records[DEFAULT_REQUEST_STORE_SIZE];
	struct persistent_setup_block *next;
} persistent_setup_block_t;

typedef struct persistent_setup_stream {
	MPI_Comm comm;
	int peer_rank;
	int tag;
	uint64_t
	    next_sequence[2]; /* Local SEND and RECV initialization order. */
	persistent_setup_record_t *pending;
	struct persistent_setup_stream *next;
} persistent_setup_stream_t;

typedef struct mpiext_persistent_ctx {
	struct fi_info *fi;
	struct fid_fabric *fabric;
	struct fid_domain *domain;
	struct fid_cq *cq;
	struct fid_av *av;
	struct fid_ep *ep;
	fi_addr_t *peer_addr;
	int n_peers;
	int my_world_rank;
	int error;
} mpiext_persistent_ctx_t;

typedef struct persistent_request {
	uint64_t remote_data_addr;
	uint64_t remote_flag_addr;
	uint64_t remote_data_mkey;
	uint64_t remote_flag_mkey;
	uint64_t posted_ops;
	uint64_t completed_ops;
	size_t size;
	size_t my_rdma_info_size;
	struct fid_mr *data_buffer_mr;
	struct fid_mr *flag_buffer_mr;
	void *data_buffer;
	void *my_rdma_info_buffer;
	uint32_t remote_store_index;
	int flag_buffer;
	int tag;
	int peer_rank;
	int store_index;
	MPI_Comm req_comm;
	mpiext_persistent_request_init_state_t init_state;
	mpiext_persistent_op_type_t op_type;
	request_store_state_t req_state;
	int error;
	fi_addr_t peer_addr;
	persistent_setup_stream_t *setup_stream;
	uint64_t setup_sequence;
	bool buffered;
	bool buffered_active;
	bool slot_available[2];
	bool slot_ready[2];
	void *bounce_buffer;
	size_t remote_size;
	uint64_t buffered_sent;
	uint64_t buffered_consumed;
} persistent_request_t;

typedef struct request_element {
	uint32_t index;
	struct request_element *next;
} request_element_t;

static mpiext_persistent_ctx_t ctx;

static persistent_request_t *request_store = NULL;
static request_element_t *free_requests_head = NULL;
static request_element_t *free_requests_tail = NULL;
static request_element_t *request_element_mpool = NULL;
static persistent_setup_stream_t *setup_streams = NULL;
static persistent_setup_block_t *setup_blocks = NULL;
static persistent_setup_record_t *free_setup_records = NULL;

/* Independent of request storage: start with the same capacity and grow in
 * equally sized blocks if unmatched remote metadata exceeds that capacity. */
static int mpiext_persistent_grow_setup_pool(void) {
	persistent_setup_block_t *block = malloc(sizeof(*block));
	if (block == NULL) return MPI_ERR_NO_MEM;
	block->next = setup_blocks;
	setup_blocks = block;
	for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE; ++i) {
		block->records[i].next = free_setup_records;
		free_setup_records = &block->records[i];
	}
	return OMPI_SUCCESS;
}

static inline persistent_setup_record_t *mpiext_persistent_get_setup_record(
    void) {
	if (free_setup_records == NULL &&
	    mpiext_persistent_grow_setup_pool() != OMPI_SUCCESS)
		return NULL;
	persistent_setup_record_t *record = free_setup_records;
	free_setup_records = record->next;
	record->next = NULL;
	return record;
}

static inline void mpiext_persistent_put_setup_record(
    persistent_setup_record_t *record) {
	record->next = free_setup_records;
	free_setup_records = record;
}

static void mpiext_persistent_forget_setup(persistent_request_t *request) {
	if (request->setup_stream == NULL) return;
	uint64_t remote_type = request->op_type == PERSISTENT_SEND
				   ? PERSISTENT_RECV
				   : PERSISTENT_SEND;
	persistent_setup_record_t **link = &request->setup_stream->pending;
	while (*link != NULL) {
		persistent_setup_record_t *record = *link;
		if (record->words[5] == remote_type &&
		    record->words[6] == request->setup_sequence) {
			*link = record->next;
			mpiext_persistent_put_setup_record(record);
		} else {
			link = &record->next;
		}
	}
}

static int mpiext_persistent_get_setup_stream(
    persistent_request_t *request, persistent_setup_stream_t **result) {
	for (persistent_setup_stream_t *stream = setup_streams; stream;
	     stream = stream->next) {
		if (stream->comm == request->req_comm &&
		    stream->peer_rank == request->peer_rank &&
		    stream->tag == request->tag) {
			*result = stream;
			return OMPI_SUCCESS;
		}
	}

	persistent_setup_stream_t *stream = calloc(1, sizeof(*stream));
	if (stream == NULL) return MPI_ERR_NO_MEM;
	stream->comm = request->req_comm;
	/* Keep communicator identity and sequence counters across request
	 * reuse. Retention prevents a freed communicator's address from being
	 * recycled. */
	OBJ_RETAIN(stream->comm);
	stream->peer_rank = request->peer_rank;
	stream->tag = request->tag;
	stream->next = setup_streams;
	setup_streams = stream;
	*result = stream;
	return OMPI_SUCCESS;
}

static void mpiext_persistent_cleanup_setup(void) {
	while (setup_streams != NULL) {
		persistent_setup_stream_t *stream = setup_streams;
		setup_streams = stream->next;
		while (stream->pending != NULL) {
			persistent_setup_record_t *record = stream->pending;
			stream->pending = record->next;
			mpiext_persistent_put_setup_record(record);
		}
		OBJ_RELEASE(stream->comm);
		free(stream);
	}
	free_setup_records = NULL;
	while (setup_blocks != NULL) {
		persistent_setup_block_t *block = setup_blocks;
		setup_blocks = block->next;
		free(block);
	}
}

PERSISTENT_ALWAYS_INLINE static inline void
mpiext_persistent_cleanup_request_ressources(persistent_request_t *req) {
	mpiext_persistent_forget_setup(req);
	if (req->data_buffer_mr) fi_close(&req->data_buffer_mr->fid);
	if (req->flag_buffer_mr) fi_close(&req->flag_buffer_mr->fid);
	free(req->bounce_buffer);
	free(req->my_rdma_info_buffer);
}

static inline void free_requests_append(request_element_t *elem) {
	elem->next = NULL;
	if (free_requests_head == NULL) {
		free_requests_head = elem;
		free_requests_tail = elem;

	} else {
		free_requests_tail->next = elem;
		free_requests_tail = elem;
	}
}

// forward declaration
static inline void mpiext_persistent_reset_request(
    persistent_request_t *request);
static inline void cleanup_request_storage(void);

static inline int init_request_storage(void) {
	request_element_t *elem = NULL;

	request_store =
	    malloc(DEFAULT_REQUEST_STORE_SIZE * sizeof(persistent_request_t));
	if (!request_store) {
		OPT_PERSISTENT_ERR("request_store alloc failed");
		return MPI_ERR_NO_MEM;
	}

	for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE; ++i) {
		request_store[i].req_state = REQ_FREE;
		request_store[i].store_index = i;
		mpiext_persistent_reset_request(&request_store[i]);
	}

	for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE; ++i) {
		elem = malloc(sizeof(request_element_t));

		if (!elem) {
			OPT_PERSISTENT_ERR("elem alloc failed");
			cleanup_request_storage();
			return MPI_ERR_NO_MEM;
		}

		elem->index = i;
		elem->next = NULL;

		free_requests_append(elem);
	}
	return OMPI_SUCCESS;
}

static inline void cleanup_request_storage(void) {
	request_element_t *elem = free_requests_head;

	while (elem != NULL) {
		request_element_t *next = elem->next;
		free(elem);
		elem = next;
	}

	free_requests_head = NULL;
	free_requests_tail = NULL;

	elem = request_element_mpool;

	while (elem != NULL) {
		request_element_t *next = elem->next;
		free(elem);
		elem = next;
	}

	request_element_mpool = NULL;

	for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE; ++i) {
		if (request_store[i].req_state == REQ_FREE) continue;

		mpiext_persistent_cleanup_request_ressources(&request_store[i]);
	}

	free(request_store);
	request_store = NULL;
}

static inline void request_element_mpool_put(request_element_t *elem) {
	elem->index = -1;
	elem->next = NULL;

	if (request_element_mpool == NULL) {
		request_element_mpool = elem;
	} else {
		// LIFO
		elem->next = request_element_mpool;
		request_element_mpool = elem;
	}
}

static inline request_element_t *request_element_mpool_get(void) {
	request_element_t *elem = request_element_mpool;
	request_element_mpool = elem->next;
	elem->next = NULL;
	return elem;
}

static inline persistent_request_t *get_persistent_request(void) {
	request_element_t *elem = free_requests_head;
	if (PERSISTENT_UNLIKELY(elem == NULL)) return NULL;
	free_requests_head = elem->next;
	if (free_requests_head == NULL) free_requests_tail = NULL;
	persistent_request_t *req = &request_store[elem->index];

	req->req_state = REQ_ACTIVE;
	req->store_index = elem->index;

	request_element_mpool_put(elem);

	return req;
}

static inline void put_persistent_request(int index) {
	request_element_t *elem = request_element_mpool_get();

	elem->index = index;

	mpiext_persistent_cleanup_request_ressources(&request_store[index]);
	mpiext_persistent_reset_request(&request_store[index]);

	request_store[index].req_state = REQ_FREE;

	free_requests_append(elem);
}

#ifdef DEBUG
static void mpiext_persistent_print_provider_info(struct fi_info *info) {
	if (NULL != info) {
		fprintf(stderr, "Provider info:\n");
		fprintf(stderr, "   %s (%s)\n", info->fabric_attr->prov_name,
			info->domain_attr->name);

		fprintf(stderr, "  capabilities: %s\n",
			fi_tostr(&info->caps, FI_TYPE_CAPS));
		fprintf(stderr, "  mode: %s\n",
			fi_tostr(&info->mode, FI_TYPE_MODE));
		if (info->mode & FI_CONTEXT) fprintf(stderr, "FI_CONTEXT\n");
		if (info->mode & FI_CONTEXT2) fprintf(stderr, "FI_CONTEXT2\n");

		struct fi_domain_attr *domain_attr = info->domain_attr;
		fprintf(stderr, "Domain attributes:\n");
		fprintf(stderr, "  threading: %s\n",
			fi_tostr(&domain_attr->threading, FI_TYPE_THREADING));
		fprintf(
		    stderr, "  data progress mode %s\n",
		    fi_tostr(&domain_attr->data_progress, FI_TYPE_PROGRESS));
		fprintf(
		    stderr, "  control progress mode %s\n",
		    fi_tostr(&domain_attr->control_progress, FI_TYPE_PROGRESS));
		fprintf(stderr, "  MR mode %s\n",
			fi_tostr(&domain_attr->mr_mode, FI_TYPE_MR_MODE));

		struct fi_tx_attr *tx_attr = info->tx_attr;
		fprintf(stderr, "Tx attributes:\n");
		fprintf(stderr, "  tx iov_limit: %ld\n", tx_attr->iov_limit);
		fprintf(stderr, "  tx rma_iov_limit: %ld\n",
			tx_attr->rma_iov_limit);
	}
}
#endif

static inline void mpiext_persistent_reset_request(
    persistent_request_t *request) {
	request->posted_ops = 0;
	request->completed_ops = 0;
	request->remote_data_addr = 0;
	request->remote_flag_addr = 0;
	request->remote_data_mkey = 0;
	request->remote_flag_mkey = 0;
	request->data_buffer_mr = NULL;
	request->flag_buffer_mr = NULL;
	request->size = 0;
	request->my_rdma_info_size = 0;
	request->data_buffer = NULL;
	request->my_rdma_info_buffer = NULL;
	request->flag_buffer = -1;
	request->tag = -1;
	request->req_comm = MPI_COMM_NULL;
	request->peer_rank = -1;
	request->peer_addr = FI_ADDR_NOTAVAIL;
	request->init_state = CHECK_FOR_REMOTE_INFO;
	request->op_type = OP_INVALID;
	request->error = OMPI_SUCCESS;
	request->setup_stream = NULL;
	request->setup_sequence = 0;
	request->buffered = false;
	request->buffered_active = false;
	request->slot_available[0] = request->slot_available[1] = true;
	request->slot_ready[0] = request->slot_ready[1] = false;
	request->bounce_buffer = NULL;
	request->remote_size = 0;
	request->buffered_sent = 0;
	request->buffered_consumed = 0;
}

static inline int mpiext_persistent_get_ep(ompi_communicator_t *comm,
					   int target_rank,
					   fi_addr_t *address) {
	int ret;
	char *peer_addr = NULL;
	uint64_t addr_len = 0;
	fi_addr_t inserted_addr = FI_ADDR_NOTAVAIL;

	*address = FI_ADDR_NOTAVAIL;
	if (ompi_comm_invalid(comm)) return MPI_ERR_COMM;
	if (target_rank < 0 ||
	    target_rank >= comm->c_remote_group->grp_proc_count)
		return MPI_ERR_RANK;

	ompi_proc_t *proc = ompi_comm_peer_lookup(comm, target_rank);
	if (proc == NULL) return MPI_ERR_RANK;

	uint32_t global_rank = proc->super.proc_name.vpid;

	if (ctx.peer_addr[global_rank] != FI_ADDR_NOTAVAIL) {
		*address = ctx.peer_addr[global_rank];
		return OMPI_SUCCESS;
	}

	OPAL_MODEX_RECV_STRING(ret, MPIEXT_PERSISTENT_ADDR_KEY,
			       &proc->super.proc_name, (void **)&peer_addr,
			       &addr_len);
	if (ret != PMIX_SUCCESS || peer_addr == NULL || addr_len == 0) {
		OPT_PERSISTENT_ERR("Peer address lookup failed: %d", ret);
		free(peer_addr);
		return MPI_ERR_OTHER;
	}

	ret = fi_av_insert(ctx.av, peer_addr, 1, &inserted_addr, 0, NULL);
	free(peer_addr);
	if (ret != 1 || inserted_addr == FI_ADDR_NOTAVAIL) {
		OPT_PERSISTENT_ERR("Peer address insertion failed: %d", ret);
		return MPI_ERR_OTHER;
	}

	ctx.peer_addr[global_rank] = inserted_addr;
	*address = inserted_addr;
	return OMPI_SUCCESS;
}

static int mpiext_persistent_init(void) {
	bool wantit;
	pmix_info_t info;
	int ret;
	struct fi_info *hints = NULL;
	struct fi_cq_attr cq_attr = {0};
	struct fi_av_attr av_attr = {0};
	char addr[64];
	uint64_t addr_len = 64;
	int my_rank, world_size;

	my_rank = opal_process_info.myprocid.rank;
	world_size = opal_process_info.num_procs;

	hints = fi_allocinfo();
	assert(hints != NULL);

	hints->ep_attr->type = FI_EP_RDM;
	hints->caps = FI_RMA | FI_WRITE | FI_REMOTE_WRITE;
	hints->domain_attr->resource_mgmt = FI_RM_ENABLED;
	hints->mode = FI_CONTEXT | FI_CONTEXT2;
	hints->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_ENDPOINT |
				      FI_MR_ALLOCATED | FI_MR_PROV_KEY |
				      FI_MR_VIRT_ADDR;
	hints->domain_attr->threading = FI_THREAD_DOMAIN;
	hints->domain_attr->data_progress = FI_PROGRESS_MANUAL;
	hints->addr_format = FI_FORMAT_UNSPEC;

	ret = fi_getinfo(FI_VERSION(2, 6), NULL, NULL, 0, hints, &ctx.fi);
	assert(ret == 0);
	fi_freeinfo(hints);

#ifdef DEBUG
	if (my_rank == 0) {
		mpiext_persistent_print_provider_info(ctx.fi);
	}
#endif

	ret = fi_fabric(ctx.fi->fabric_attr, &ctx.fabric, NULL);
	assert(ret == 0);

	ret = fi_domain(ctx.fabric, ctx.fi, &ctx.domain, NULL);
	assert(ret == 0);

	cq_attr.format = FI_CQ_FORMAT_DATA;
	cq_attr.wait_obj = FI_WAIT_NONE;

	ret = fi_cq_open(ctx.domain, &cq_attr, &ctx.cq, NULL);
	assert(ret == 0);

	av_attr.type = FI_AV_TABLE;
	av_attr.count = world_size;

	ctx.n_peers = world_size;

	ret = fi_av_open(ctx.domain, &av_attr, &ctx.av, NULL);
	assert(ret == 0);

	ret = fi_endpoint(ctx.domain, ctx.fi, &ctx.ep, NULL);
	assert(ret == 0);
	ret = fi_ep_bind(ctx.ep, &ctx.cq->fid,
			 FI_TRANSMIT | FI_SELECTIVE_COMPLETION | FI_RECV);
	assert(ret == 0);

	ret = fi_ep_bind(ctx.ep, &ctx.av->fid, 0);
	assert(ret == 0);

	/* Enable the endpoint: from this point data-path calls are valid. */
	ret = fi_enable(ctx.ep);
	assert(ret == 0);

	/* Publish our ep address */

	ret = fi_getname(&ctx.ep->fid, &addr[0], &addr_len);
	assert(ret == 0);

	OPT_PERSISTENT_INFO("My ep addr: %lu", (uint64_t)addr);
	OPT_PERSISTENT_INFO("My ep addr_len: %lu", addr_len);

	ctx.peer_addr = calloc(ctx.n_peers, sizeof(fi_addr_t));
	if (ctx.peer_addr == NULL) return MPI_ERR_NO_MEM;
	for (int i = 0; i < ctx.n_peers; ++i)
		ctx.peer_addr[i] = FI_ADDR_NOTAVAIL;

	OPAL_MODEX_SEND_STRING(ret, PMIX_GLOBAL, MPIEXT_PERSISTENT_ADDR_KEY,
			       (void *)&addr, addr_len);
	assert(ret == 0);

	PMIx_Commit();
	PMIX_INFO_CONSTRUCT(&info);
	PMIX_INFO_LOAD(&info, PMIX_COLLECT_DATA, &wantit, PMIX_BOOL);
	PMIx_Fence(NULL, 0, &info, 1);
	PMIX_INFO_DESTRUCT(&info);

	ctx.my_world_rank = my_rank;
	ret = init_request_storage();
	if (ret != OMPI_SUCCESS) return ret;
	ret = mpiext_persistent_grow_setup_pool();
	if (ret != OMPI_SUCCESS) cleanup_request_storage();
	return ret;
}

static inline int mpiext_persistent_register_memory(
    persistent_request_t *request) {
	void *registered_buffer = request->data_buffer;
	size_t registered_size = request->size;
	if (request->buffered && request->op_type == PERSISTENT_RECV) {
		if (request->size > SIZE_MAX / 2) return MPI_ERR_COUNT;
		registered_size = request->size ? 2 * request->size : 2;
		if (posix_memalign(&request->bounce_buffer, 64,
				   registered_size) != 0)
			return MPI_ERR_NO_MEM;
		registered_buffer = request->bounce_buffer;
	} else if (request->buffered && registered_size == 0) {
		registered_size = 1;
	}
	int ret = fi_mr_reg(ctx.domain, registered_buffer, registered_size,
			    FI_WRITE | FI_REMOTE_WRITE, 0, 0, 0,
			    &request->data_buffer_mr, NULL);
	if (ret < 0) {
		OPT_PERSISTENT_ERR("Data MR alloc failed");
		return MPI_ERR_OTHER;
	}

	ret = fi_mr_reg(ctx.domain, &request->flag_buffer, sizeof(int),
			FI_WRITE | FI_REMOTE_WRITE, 0, 0, 0,
			&request->flag_buffer_mr, NULL);
	if (ret < 0) {
		OPT_PERSISTENT_ERR("Flag MR alloc failed");
		return MPI_ERR_OTHER;
	}

	OPT_PERSISTENT_INFO("[setup] DATA MR key (local)    : 0x%lx",
			    fi_mr_key(request->data_buffer_mr));
	OPT_PERSISTENT_INFO("[setup] DATA MR vaddr          : %p",
			    (void *)request->data_buffer);
	OPT_PERSISTENT_INFO("[setup] FLAG MR key (local)    : 0x%lx",
			    fi_mr_key(request->flag_buffer_mr));
	OPT_PERSISTENT_INFO("[setup] FLAG MR vaddr          : %p",
			    (void *)&request->flag_buffer);
	return OMPI_SUCCESS;
}

PERSISTENT_ALWAYS_INLINE static inline void mpiext_persistent_pack_rdma_info(
    persistent_request_t *request) {
	uint64_t *packed = request->my_rdma_info_buffer;
	packed[0] = (uint64_t)(request->bounce_buffer ? request->bounce_buffer
						      : request->data_buffer);
	packed[1] = fi_mr_key(request->data_buffer_mr);
	packed[2] = (uint64_t)&request->flag_buffer;
	packed[3] = fi_mr_key(request->flag_buffer_mr);
	packed[4] = (uint64_t)request->store_index;
	packed[5] = (uint64_t)request->op_type;
	packed[6] = request->setup_sequence;
	packed[7] = PERSISTENT_SETUP_MAGIC;
	packed[8] = request->buffered;
	packed[9] = request->size;
}

PERSISTENT_ALWAYS_INLINE static inline int mpiext_persistent_unpack_rdma_info(
    persistent_request_t *request, void *payload) {
	uint64_t *packed = payload;
	if (packed[8] != (uint64_t)request->buffered) {
		OPT_PERSISTENT_ERR("Buffered mode must match on both peers");
		return request->error = MPI_ERR_ARG;
	}
	request->remote_size = packed[9];
	if (request->buffered && (request->op_type == PERSISTENT_SEND
				      ? request->size > request->remote_size
				      : request->remote_size > request->size))
		return request->error = MPI_ERR_TRUNCATE;
	request->remote_data_addr = packed[0];
	request->remote_data_mkey = packed[1];
	request->remote_flag_addr = packed[2];
	request->remote_flag_mkey = packed[3];
	request->remote_store_index = (uint32_t)packed[4];
	return OMPI_SUCCESS;
}

static void mpiext_persistent_cleanup_module(void) {
	if (ctx.av) {
		fi_close(&ctx.av->fid);
	}
	if (ctx.cq) {
		fi_close(&ctx.cq->fid);
	}
	if (ctx.domain) {
		fi_close(&ctx.domain->fid);
	}
	if (ctx.fabric) {
		fi_close(&ctx.fabric->fid);
	}
	if (ctx.fi) {
		fi_freeinfo(ctx.fi);
	}
}

static int mpiext_persistent_fini(void) {
	if (buffered_progress_registered) {
		opal_progress_unregister(mpiext_persistent_buffered_progress);
		buffered_progress_registered = false;
	}
	cleanup_request_storage();
	mpiext_persistent_cleanup_setup();
	mpiext_persistent_cleanup_module();
	return OMPI_SUCCESS;
}

ompi_mpiext_component_t ompi_mpiext_persistent = {mpiext_persistent_init,
						  mpiext_persistent_fini};

static int mpiext_persistent_init_request(persistent_request_t *request) {
	persistent_setup_stream_t *stream;
	int ret = mpiext_persistent_register_memory(request);
	if (ret != OMPI_SUCCESS) goto fail;
	request->my_rdma_info_size = PERSISTENT_SETUP_WORDS * sizeof(uint64_t);

	request->my_rdma_info_buffer = malloc(request->my_rdma_info_size);
	if (request->my_rdma_info_buffer == NULL) {
		ret = MPI_ERR_NO_MEM;
		goto fail;
	}

	ret = mpiext_persistent_get_setup_stream(request, &stream);
	if (ret != OMPI_SUCCESS) goto fail;
	int direction = request->op_type - PERSISTENT_SEND;
	if (stream->next_sequence[direction] == UINT64_MAX) {
		ret = MPI_ERR_OTHER;
		goto fail;
	}
	request->setup_sequence = stream->next_sequence[direction];
	mpiext_persistent_pack_rdma_info(request);

	// We assume eager protocol usage here
	ret = PMPI_Send(request->my_rdma_info_buffer,
			request->my_rdma_info_size, MPI_BYTE,
			request->peer_rank, request->tag, request->req_comm);
	if (ret != OMPI_SUCCESS) goto fail;

	stream->next_sequence[direction]++;
	request->setup_stream = stream;
	return OMPI_SUCCESS;
fail:
	put_persistent_request(request->store_index);
	return ret;
}

static inline int mpiext_persistent_request_error(
    persistent_request_t *request) {
	return ctx.error != OMPI_SUCCESS ? ctx.error : request->error;
}

PERSISTENT_ALWAYS_INLINE static inline int mpiext_persistent_progress(
    int count, struct fi_cq_data_entry cqes[]) {
	struct fi_cq_err_entry err = {0};
	persistent_request_t *request = NULL;
	ssize_t rc;

	if (PERSISTENT_UNLIKELY(ctx.error != OMPI_SUCCESS)) return ctx.error;

	rc = fi_cq_read(ctx.cq, cqes, count);

	if (rc > 0) {
		for (ssize_t i = 0; i < rc; ++i) {
			if (cqes[i].flags & FI_REMOTE_WRITE) {
				uint32_t data = (uint32_t)cqes[i].data;
				request =
				    &request_store[data &
						   PERSISTENT_CQ_INDEX_MASK];
				unsigned slot = !!(data & PERSISTENT_CQ_SLOT);
				if (request->req_state != REQ_ACTIVE ||
				    (data & ~(PERSISTENT_CQ_INDEX_MASK |
					      PERSISTENT_CQ_SLOT |
					      PERSISTENT_CQ_CREDIT)))
					return ctx.error = MPI_ERR_OTHER;
				if (data & PERSISTENT_CQ_CREDIT) {
					if (!request->buffered ||
					    request->op_type !=
						PERSISTENT_SEND ||
					    request->slot_available[slot])
						return ctx.error =
							   MPI_ERR_OTHER;
					request->slot_available[slot] = true;
				} else if (request->buffered) {
					if (request->op_type !=
						PERSISTENT_RECV ||
					    request->slot_ready[slot])
						return ctx.error =
							   MPI_ERR_OTHER;
					request->slot_ready[slot] = true;
					request->completed_ops++;
				} else {
					request->completed_ops++;
				}
			} else if (cqes[i].flags & FI_WRITE) {
				request = cqes[i].op_context;
				request->completed_ops++;
			}
		}
	}

	if (PERSISTENT_UNLIKELY(rc == -FI_EAVAIL)) {
		rc = fi_cq_readerr(ctx.cq, &err, 0);
		if (rc != 1) {
			OPT_PERSISTENT_ERR("fi_cq_readerr failed: %zd", rc);
			return ctx.error = MPI_ERR_OTHER;
		}

		OPT_PERSISTENT_ERR("CQ: %s",
				   fi_cq_strerror(ctx.cq, err.prov_errno,
						  err.err_data, NULL, 0));

		if ((err.flags & FI_WRITE) && err.op_context != NULL) {
			for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE;
			     ++i) {
				if (err.op_context == &request_store[i] &&
				    request_store[i].req_state == REQ_ACTIVE) {
					request_store[i].error = MPI_ERR_OTHER;
					return OMPI_SUCCESS;
				}
			}
		}
		return ctx.error = MPI_ERR_OTHER;
	}

	if (PERSISTENT_UNLIKELY(rc < 0 && rc != -FI_EAGAIN)) {
		OPT_PERSISTENT_ERR("fi_cq_read failed with %s",
				   fi_strerror(-rc));
		return ctx.error = MPI_ERR_OTHER;
	}
	return 0;
}

static inline int mpiext_persistent_progress_request(
    persistent_request_t *request) {
	struct fi_cq_data_entry cqe[MPIEXT_PERSISTENT_DEFAULT_COMP];
	int ret =
	    mpiext_persistent_progress(MPIEXT_PERSISTENT_DEFAULT_COMP, cqe);
	return ret != OMPI_SUCCESS ? ret
				   : mpiext_persistent_request_error(request);
}

static int mpiext_persistent_buffered_progress(void) {
	/* RxM needs progress even when a sender has completed its injected
	 * writes and is waiting in ordinary MPI for the receiver. Errors remain
	 * latched for the next extension call. This callback never copies
	 * application data. */
	struct fi_cq_data_entry cqe[MPIEXT_PERSISTENT_DEFAULT_COMP];
	if (ctx.error == OMPI_SUCCESS)
		mpiext_persistent_progress(MPIEXT_PERSISTENT_DEFAULT_COMP, cqe);
	return 0;
}

PERSISTENT_ALWAYS_INLINE static inline int
mpiext_persistent_start_data_transfer(persistent_request_t *request) {
	ssize_t ret = -1;
	void *desc = fi_mr_desc(request->data_buffer_mr);
	uint64_t flags = 0;
	unsigned slot = request->buffered ? request->buffered_sent % 2 : 0;

	struct fi_rma_iov rma_iov = {
	    .addr = request->remote_data_addr + slot * request->remote_size,
	    .len = request->size,
	    .key = request->remote_data_mkey,
	};

	struct iovec iov = {
	    .iov_base = request->data_buffer,
	    .iov_len = request->size,
	};

	struct fi_msg_rma rma_msg = {
	    .msg_iov = &iov,
	    .desc = &desc,
	    .iov_count = 1,
	    .addr = request->peer_addr,
	    .rma_iov = &rma_iov,
	    .rma_iov_count = 1,
	    .context = (void *)request,
	    .data =
		request->remote_store_index | (slot ? PERSISTENT_CQ_SLOT : 0),
	};

	flags = FI_REMOTE_CQ_DATA;

	if (request->size <= ctx.fi->tx_attr->inject_size) {
		flags |= FI_INJECT;
	} else {
		flags |= FI_COMPLETION;
	}

	do {
		ret = fi_writemsg(ctx.ep, &rma_msg, flags);
		if (ret == -FI_EAGAIN) {
			int progress_ret =
			    mpiext_persistent_progress_request(request);
			if (progress_ret != OMPI_SUCCESS) return progress_ret;
		} else if (ret < 0) {
			OPT_PERSISTENT_ERR("fi_writemsg data failed with %s",
					   fi_strerror(-ret));
			return request->error = MPI_ERR_OTHER;
		}
	} while (ret);

	if (flags & FI_COMPLETION) request->posted_ops++;
	return 0;
}

PERSISTENT_ALWAYS_INLINE static inline int
mpiext_persistent_start_flag_transfer(persistent_request_t *request) {
	ssize_t ret = -1;

	do {
		ret = fi_inject_write(ctx.ep, &request->flag_buffer,
				      sizeof(int), request->peer_addr,
				      request->remote_flag_addr,
				      request->remote_flag_mkey);
		if (ret == -FI_EAGAIN) {
			int progress_ret =
			    mpiext_persistent_progress_request(request);
			if (progress_ret != OMPI_SUCCESS) return progress_ret;
		} else if (ret < 0) {
			OPT_PERSISTENT_ERR("fi_writemsg data failed with %s",
					   fi_strerror(-ret));
			return request->error = MPI_ERR_OTHER;
		}
	} while (ret);

	return 0;
}

static inline int mpiext_persistent_start_send_core_no_sync(
    persistent_request_t *request) {
	return mpiext_persistent_start_data_transfer(request);
}

static inline int mpiext_persistent_start_send_core(
    persistent_request_t *request) {
	volatile int *flag = &request->flag_buffer;
	OPT_PERSISTENT_INFO("Waiting for RTR flag on %i from %i on addr %p\n",
			    ctx.my_world_rank, request->peer_rank,
			    &request->flag_buffer);
	while (*flag != READY_TO_RECEIVE_FLAG) {
		int ret = mpiext_persistent_progress_request(request);
		if (ret != OMPI_SUCCESS) return ret;
	}
	request->flag_buffer = 0;
	OPT_PERSISTENT_INFO("Got RTR flag\n");

	return mpiext_persistent_start_data_transfer(request);
}

static inline int mpiext_persistent_finalize_send_core(
    persistent_request_t *request) {
	while (request->posted_ops != request->completed_ops) {
		int ret = mpiext_persistent_progress_request(request);
		if (ret != OMPI_SUCCESS) return ret;
	}

	OPT_PERSISTENT_INFO("SEND OPERATION FINALIZED");
	return mpiext_persistent_request_error(request);
}

static inline int mpiext_persistent_start_recv_core_no_sync(
    persistent_request_t *request) {
	request->posted_ops++;
	return 0;
}

static inline int mpiext_persistent_start_recv_core(
    persistent_request_t *request) {
	request->flag_buffer = READY_TO_RECEIVE_FLAG;
	OPT_PERSISTENT_INFO("Sending RTR flag to %i from %i to addr 0x%lx\n",
			    request->peer_rank, ctx.my_world_rank,
			    request->remote_flag_addr);
	int ret = mpiext_persistent_start_flag_transfer(request);
	if (ret == OMPI_SUCCESS) request->posted_ops++;
	return ret;
}

static inline int mpiext_persistent_finalize_recv_core(
    persistent_request_t *request) {
	while (request->completed_ops < request->posted_ops) {
		int ret = mpiext_persistent_progress_request(request);
		if (ret != OMPI_SUCCESS) return ret;
	}
	OPT_PERSISTENT_INFO("Finalized Recv operation");
	return mpiext_persistent_request_error(request);
}

/* True if this record belongs to an initialization not yet seen locally, or
 * to a live request. Discard late metadata for freed, unstarted requests. */
static bool mpiext_persistent_setup_needed(
    persistent_setup_stream_t *stream,
    const persistent_setup_record_t *record) {
	mpiext_persistent_op_type_t local_type =
	    record->words[5] == PERSISTENT_SEND ? PERSISTENT_RECV
						: PERSISTENT_SEND;
	if (record->words[6] >=
	    stream->next_sequence[local_type - PERSISTENT_SEND])
		return true;
	for (uint32_t i = 0; i < DEFAULT_REQUEST_STORE_SIZE; ++i) {
		persistent_request_t *candidate = &request_store[i];
		if (candidate->req_state == REQ_ACTIVE &&
		    candidate->setup_stream == stream &&
		    candidate->op_type == local_type &&
		    candidate->setup_sequence == record->words[6] &&
		    candidate->init_state == CHECK_FOR_REMOTE_INFO)
			return true;
	}
	return false;
}

static int mpiext_persistent_match_setup(persistent_request_t *request) {
	persistent_setup_stream_t *stream = request->setup_stream;
	uint64_t remote_type = request->op_type == PERSISTENT_SEND
				   ? PERSISTENT_RECV
				   : PERSISTENT_SEND;
	persistent_setup_record_t **link = &stream->pending;
	while (*link != NULL) {
		persistent_setup_record_t *record = *link;
		if (record->words[5] == remote_type &&
		    record->words[6] == request->setup_sequence) {
			*link = record->next;
			int ret = mpiext_persistent_unpack_rdma_info(
			    request, record->words);
			mpiext_persistent_put_setup_record(record);
			return ret;
		}
		link = &record->next;
	}

	for (;;) {
		/* Reserve a pooled record before consuming a message so pool
		 * growth failure cannot lose another request's metadata. */
		persistent_setup_record_t *record =
		    mpiext_persistent_get_setup_record();
		if (record == NULL) return request->error = MPI_ERR_NO_MEM;
		MPI_Status status;
		int ret = PMPI_Recv(record->words, sizeof(record->words),
				    MPI_BYTE, request->peer_rank, request->tag,
				    request->req_comm, &status);
		if (ret != OMPI_SUCCESS) {
			mpiext_persistent_put_setup_record(record);
			return ctx.error = ret;
		}
		int bytes;
		ret = PMPI_Get_count(&status, MPI_BYTE, &bytes);
		if (ret != OMPI_SUCCESS || bytes != sizeof(record->words) ||
		    record->words[7] != PERSISTENT_SETUP_MAGIC ||
		    (record->words[5] != PERSISTENT_SEND &&
		     record->words[5] != PERSISTENT_RECV) ||
		    record->words[4] >= DEFAULT_REQUEST_STORE_SIZE ||
		    record->words[6] == UINT64_MAX) {
			OPT_PERSISTENT_ERR(
			    "Invalid persistent setup record from rank %d, tag "
			    "%d",
			    request->peer_rank, request->tag);
			mpiext_persistent_put_setup_record(record);
			return ctx.error = MPI_ERR_OTHER;
		}
		if (record->words[5] == remote_type &&
		    record->words[6] == request->setup_sequence) {
			ret = mpiext_persistent_unpack_rdma_info(request,
								 record->words);
			mpiext_persistent_put_setup_record(record);
			return ret;
		}
		if (mpiext_persistent_setup_needed(stream, record)) {
			record->next = stream->pending;
			stream->pending = record;
		} else {
			mpiext_persistent_put_setup_record(record);
		}
	}
}

PERSISTENT_ALWAYS_INLINE static inline int
mpiext_persistent_finialize_init_first_no_sync(persistent_request_t *request) {
	int ret = mpiext_persistent_match_setup(request);
	if (ret != OMPI_SUCCESS) return ret;

	request->init_state = READY;

	// Start operation after we finished init
	if (request->op_type == PERSISTENT_SEND) {
		OPT_PERSISTENT_INFO("ready send operation on %i",
				    ctx.my_world_rank);
		return mpiext_persistent_start_send_core_no_sync(request);
	} else {
		OPT_PERSISTENT_INFO("ready recv operation on %i\n",
				    ctx.my_world_rank);
		return mpiext_persistent_start_recv_core_no_sync(request);
	}
}

PERSISTENT_ALWAYS_INLINE static inline int
mpiext_persistent_finialize_init_first(persistent_request_t *request) {
	int ret = mpiext_persistent_match_setup(request);
	if (ret != OMPI_SUCCESS) return ret;

	// important: check ready state here
	request->init_state = READY;

	// Start operation after we finished init
	if (request->op_type == PERSISTENT_SEND) {
		OPT_PERSISTENT_INFO("ready send operation on %i",
				    ctx.my_world_rank);
		return mpiext_persistent_start_send_core(request);
	} else {
		OPT_PERSISTENT_INFO("ready recv operation on %i\n",
				    ctx.my_world_rank);
		return mpiext_persistent_start_recv_core(request);
	}
}

static inline bool mpiext_persistent_use_eager(size_t bytes) {
	return bytes > ctx.fi->tx_attr->inject_size &&
	       bytes <= PERSISTENT_EAGER_MAX;
}

static int mpiext_persistent_message_size(int count, MPI_Datatype datatype,
					  size_t *bytes) {
	if (count < 0) return MPI_ERR_COUNT;
	if (datatype == MPI_DATATYPE_NULL) return MPI_ERR_TYPE;
	int size;
	int ret = PMPI_Type_size(datatype, &size);
	if (ret != MPI_SUCCESS) return ret;
	if (size < 0 || (size != 0 && (size_t)count > SIZE_MAX / (size_t)size))
		return MPI_ERR_COUNT;
	*bytes = (size_t)size * (size_t)count;
	return OMPI_SUCCESS;
}

/* A separate initialization API fixes the mode before addresses are exchanged.
 * Buffered requests subsequently use the ordinary Start/Wait entry points. */
static int mpiext_persistent_init_buffered(void *buffer, int count,
					   MPI_Datatype datatype, int peer,
					   int tag, MPI_Comm comm,
					   mpiext_persistent_op_type_t op,
					   MPI_Request *result) {
	if (result == NULL) return MPI_ERR_ARG;
	*result = NULL;
	if (count < 0) return MPI_ERR_COUNT;
	if (buffer == NULL) return MPI_ERR_BUFFER;
	if (datatype == MPI_DATATYPE_NULL) return MPI_ERR_TYPE;
	int size;
	MPI_Aint lb, extent;
	int ret = PMPI_Type_size(datatype, &size);
	if (ret != MPI_SUCCESS) return ret;
	ret = PMPI_Type_get_true_extent(datatype, &lb, &extent);
	if (ret != MPI_SUCCESS) return ret;
	if (lb != 0 ||
	    !ompi_datatype_is_contiguous_memory_layout(datatype, count))
		return MPI_ERR_TYPE;
	if (size < 0 ||
	    (size != 0 && (size_t)count > SIZE_MAX / (size_t)size / 2))
		return MPI_ERR_COUNT;
	if (ctx.fi->domain_attr->cq_data_size < sizeof(uint32_t) ||
	    ctx.fi->tx_attr->inject_size < sizeof(int))
		return MPI_ERR_OTHER;
	if (!buffered_progress_registered) {
		ret =
		    opal_progress_register(mpiext_persistent_buffered_progress);
		if (ret != OPAL_SUCCESS) return MPI_ERR_OTHER;
		buffered_progress_registered = true;
	}

	persistent_request_t *request = get_persistent_request();
	if (request == NULL) return MPI_ERR_NO_MEM;
	ret = mpiext_persistent_get_ep(comm, peer, &request->peer_addr);
	if (ret != OMPI_SUCCESS) {
		put_persistent_request(request->store_index);
		return ret;
	}
	request->req_comm = comm;
	request->peer_rank = peer;
	request->tag = tag;
	request->op_type = op;
	request->buffered = true;
	request->data_buffer = buffer;
	request->size = (size_t)size * (size_t)count;
	ret = mpiext_persistent_init_request(request);
	if (ret == OMPI_SUCCESS) *result = (MPI_Request)request;
	return ret;
}

int OMPI_Psend_init(const void *buffer, int count, MPI_Datatype datatype,
		    int dst, int tag, MPI_Comm communicator,
		    MPI_Request *request) {
	size_t bytes;

	assert(buffer != NULL);

	if (request == NULL) return MPI_ERR_ARG;
	*request = NULL;
	int ret = mpiext_persistent_message_size(count, datatype, &bytes);
	if (ret != MPI_SUCCESS) return ret;
	/* Choose before registering memory or advertising the receive target.
	 * Paired automatic requests must specify equal byte counts. */
	if (mpiext_persistent_use_eager(bytes))
		return mpiext_persistent_init_buffered(
		    (void *)buffer, count, datatype, dst, tag, communicator,
		    PERSISTENT_SEND, request);
	persistent_request_t *req = get_persistent_request();

	if (req == NULL) return MPI_ERR_NO_MEM;

	ret = mpiext_persistent_get_ep(communicator, dst, &req->peer_addr);
	if (ret != OMPI_SUCCESS) {
		put_persistent_request(req->store_index);
		return ret;
	}

	req->req_comm = communicator;
	req->tag = tag;
	req->peer_rank = dst;
	req->data_buffer = buffer;
	req->op_type = PERSISTENT_SEND;

	req->size = bytes;

	OPT_PERSISTENT_INFO("[PSEND_INIT]: data buffer %p", (void *)buffer);
	ret = mpiext_persistent_init_request(req);
	if (ret == OMPI_SUCCESS) *request = (void *)req;
	return ret;
}

int OMPI_Precv_init(void *buffer, int count, MPI_Datatype datatype, int src,
		    int tag, MPI_Comm communicator, MPI_Request *request) {
	size_t bytes;
	assert(buffer != NULL);

	if (request == NULL) return MPI_ERR_ARG;
	*request = NULL;
	int ret = mpiext_persistent_message_size(count, datatype, &bytes);
	if (ret != MPI_SUCCESS) return ret;
	if (mpiext_persistent_use_eager(bytes))
		return mpiext_persistent_init_buffered(
		    (void *)buffer, count, datatype, src, tag, communicator,
		    PERSISTENT_RECV, request);

	persistent_request_t *req = get_persistent_request();

	if (req == NULL) return MPI_ERR_NO_MEM;

	ret = mpiext_persistent_get_ep(communicator, src, &req->peer_addr);
	if (ret != OMPI_SUCCESS) {
		put_persistent_request(req->store_index);
		return ret;
	}

	req->req_comm = communicator;
	req->tag = tag;
	req->peer_rank = src;
	req->data_buffer = buffer;
	req->op_type = PERSISTENT_RECV;

	req->size = bytes;

	OPT_PERSISTENT_INFO("[PRECV_INIT]: data buffer %p", (void *)buffer);
	ret = mpiext_persistent_init_request(req);
	if (ret == OMPI_SUCCESS) *request = (void *)req;
	return ret;
}



static int mpiext_persistent_start_buffered(persistent_request_t *request) {
	if (request->buffered_active) return MPI_ERR_REQUEST;
	if (request->init_state != READY) {
		int ret = mpiext_persistent_match_setup(request);
		if (ret != OMPI_SUCCESS) return ret;
		request->init_state = READY;
	}
	if (request->op_type == PERSISTENT_SEND) {
		unsigned slot = request->buffered_sent % 2;
		/* Two initially free slots. Only a full ring waits for a
		 * consumed-slot CQ event; never poll a remotely written ready
		 * flag. */
		while (!request->slot_available[slot]) {
			int ret = mpiext_persistent_progress_request(request);
			if (ret != OMPI_SUCCESS) return ret;
		}
		request->slot_available[slot] = false;
		int ret = mpiext_persistent_start_data_transfer(request);
		if (ret != OMPI_SUCCESS) {
			request->slot_available[slot] = true;
			return ret;
		}
		request->buffered_sent++;
	} else {
		request->posted_ops++;
	}
	request->buffered_active = true;
	return OMPI_SUCCESS;
}

static int mpiext_persistent_wait_buffered(persistent_request_t *request) {
	if (!request->buffered_active) return OMPI_SUCCESS;
	if (request->op_type == PERSISTENT_SEND) {
		int ret = mpiext_persistent_finalize_send_core(request);
		if (ret != OMPI_SUCCESS) return ret;
	} else {
		unsigned slot = request->buffered_consumed % 2;
		while (!request->slot_ready[slot]) {
			int ret = mpiext_persistent_progress_request(request);
			if (ret != OMPI_SUCCESS) return ret;
		}
		memcpy(request->data_buffer,
		       (char *)request->bounce_buffer + slot * request->size,
		       request->remote_size);
		request->slot_ready[slot] = false;
		uint32_t data = request->remote_store_index |
				PERSISTENT_CQ_CREDIT |
				(slot ? PERSISTENT_CQ_SLOT : 0);
		for (;;) {
			/* The payload is only an RMA sink. The sender consumes
			 * the CQ credit, not this memory value. Injection
			 * copies it immediately. */
			ssize_t ret = fi_inject_writedata(
			    ctx.ep, &request->flag_buffer, sizeof(int), data,
			    request->peer_addr, request->remote_flag_addr,
			    request->remote_flag_mkey);
			if (ret == 0) break;
			if (ret != -FI_EAGAIN) {
				OPT_PERSISTENT_ERR(
				    "Buffered credit write failed: %s",
				    fi_strerror(-ret));
				return request->error = MPI_ERR_OTHER;
			}
			int progress_ret =
			    mpiext_persistent_progress_request(request);
			if (progress_ret != OMPI_SUCCESS) return progress_ret;
		}
		request->buffered_consumed++;
	}
	request->buffered_active = false;
	return OMPI_SUCCESS;
}

static int mpiext_persistent_start_send_internal_no_sync(
    persistent_request_t *request) {
	if (PERSISTENT_LIKELY(request->init_state == READY))
		return mpiext_persistent_start_send_core_no_sync(request);
	else {
		return mpiext_persistent_finialize_init_first_no_sync(request);
	}
}

static int mpiext_persistent_start_recv_internal_no_sync(
    persistent_request_t *request) {
	if (PERSISTENT_LIKELY(request->init_state == READY))
		return mpiext_persistent_start_recv_core_no_sync(request);
	else {
		return mpiext_persistent_finialize_init_first_no_sync(request);
	}
}

static int mpiext_persistent_start_send_internal(
    persistent_request_t *request) {
	if (PERSISTENT_LIKELY(request->init_state == READY))
		return mpiext_persistent_start_send_core(request);
	else {
		return mpiext_persistent_finialize_init_first(request);
	}
}

static int mpiext_persistent_start_recv_internal(
    persistent_request_t *request) {
	if (PERSISTENT_LIKELY(request->init_state == READY))
		return mpiext_persistent_start_recv_core(request);
	else {
		return mpiext_persistent_finialize_init_first(request);
	}
}

static int mpiext_persistent_start_internal(persistent_request_t *request) {
	int ret = mpiext_persistent_request_error(request);
	if (PERSISTENT_UNLIKELY(ret != OMPI_SUCCESS)) return ret;
	if (request->buffered) return mpiext_persistent_start_buffered(request);
	if (request->op_type == PERSISTENT_SEND)
		return mpiext_persistent_start_send_internal(request);
	else
		return mpiext_persistent_start_recv_internal(request);
}

static int mpiext_persistent_start_internal_no_sync(
    persistent_request_t *request) {
	int ret = mpiext_persistent_request_error(request);
	if (PERSISTENT_UNLIKELY(ret != OMPI_SUCCESS)) return ret;
	if (request->buffered) return mpiext_persistent_start_buffered(request);
	if (request->op_type == PERSISTENT_SEND)
		return mpiext_persistent_start_send_internal_no_sync(request);
	else
		return mpiext_persistent_start_recv_internal_no_sync(request);
}

int OMPI_Start_no_sync(MPI_Request *request) {
	return mpiext_persistent_start_internal_no_sync(
	    (persistent_request_t *)*request);
}

int OMPI_Startall_no_sync(int count, MPI_Request request_array[]) {
	int ret = OMPI_ERROR;

	for (int i = 0; i < count; i++) {
		ret = mpiext_persistent_start_internal_no_sync(
		    (persistent_request_t *)*(request_array + i));
		if (PERSISTENT_UNLIKELY(OMPI_SUCCESS != ret)) {
			return ret;
		}
	}
	return OMPI_SUCCESS;
}

int OMPI_Start(MPI_Request *request) {
	return mpiext_persistent_start_internal(
	    (persistent_request_t *)*request);
}

int OMPI_Startall(int count, MPI_Request request_array[]) {
	int ret = OMPI_ERROR;

	for (int i = 0; i < count; i++) {
		if (!request_array[i]) continue;
		ret = mpiext_persistent_start_internal(
		    (persistent_request_t *)*(request_array + i));

		if (PERSISTENT_UNLIKELY(OMPI_SUCCESS != ret)) {
			return ret;
		}
	}
	return OMPI_SUCCESS;
}

static int mpiext_persistent_wait_internal(persistent_request_t *request) {
	int ret = mpiext_persistent_request_error(request);
	if (PERSISTENT_UNLIKELY(ret != OMPI_SUCCESS)) return ret;
	if (request->buffered) return mpiext_persistent_wait_buffered(request);
	if (request->op_type == PERSISTENT_SEND)
		return mpiext_persistent_finalize_send_core(request);
	else
		return mpiext_persistent_finalize_recv_core(request);
}

int OMPI_Wait(MPI_Request *request, MPI_Status *status) {
	return mpiext_persistent_wait_internal(
	    (persistent_request_t *)*request);
}

int OMPI_Waitall(int count, MPI_Request request_array[],
		 MPI_Status status_array[]) {
	int ret = OMPI_ERROR;

	for (int i = 0; i < count; i++) {
		if (!request_array[i]) continue;
		ret = mpiext_persistent_wait_internal(
		    (persistent_request_t *)*(request_array + i));
		if (PERSISTENT_UNLIKELY(OMPI_SUCCESS != ret)) {
			return ret;
		}
	}
	return OMPI_SUCCESS;
}

int OMPI_Prequest_free(MPI_Request *request) {
	if (request == NULL) return OMPI_SUCCESS;

	persistent_request_t *req = (persistent_request_t *)*request;

	if (req->buffered) {
		if (req->buffered_active) return MPI_ERR_REQUEST;
		/* Keep the credit destination registered until every accepted
		 * write has been consumed. Local send completion alone is
		 * insufficient. */
		if (req->op_type == PERSISTENT_SEND) {
			while (!req->slot_available[0] ||
			       !req->slot_available[1]) {
				int ret =
				    mpiext_persistent_progress_request(req);
				if (ret != OMPI_SUCCESS) return ret;
			}
		}
	}

	put_persistent_request(req->store_index);

	*request = NULL;

	return OMPI_SUCCESS;
}
