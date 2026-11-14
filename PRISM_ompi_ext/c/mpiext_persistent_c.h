/*
 * Copyright (c) 2004-2009 The Trustees of Indiana University.
 *                         All rights reserved.
 * Copyright (c) 2011      Oak Ridge National Labs.  All rights reserved.
 * Copyright (c) 2012 Cisco Systems, Inc.  All rights reserved.
 * $COPYRIGHT$
 *
 * Additional copyrights may follow
 *
 * $HEADER$
 *
 */

/* This file is included in <mpi-ext.h>.  It is unnecessary to protect
   it from multiple inclusion.  Also, you can assume that <mpi.h> has
   already been included, so all of its types and globals are
   available. */

OMPI_DECLSPEC int OMPI_Psend_init(const void *buffer, int count, MPI_Datatype datatype, int dst,
                                  int tag, MPI_Comm communicator, MPI_Request *request);
OMPI_DECLSPEC int OMPI_Precv_init(void *buffer, int count, MPI_Datatype datatype, int src, int tag,
                                  MPI_Comm communicator, MPI_Request *request);
OMPI_DECLSPEC int OMPI_Start(MPI_Request *request);
OMPI_DECLSPEC int OMPI_Startall(int count, MPI_Request request_array[]);
OMPI_DECLSPEC int OMPI_Wait(MPI_Request *request, MPI_Status *status);
OMPI_DECLSPEC int OMPI_Waitall(int count, MPI_Request request_array[], MPI_Status status_array[]);
OMPI_DECLSPEC int OMPI_Prequest_free(MPI_Request *req);

OMPI_DECLSPEC int OMPI_Start_no_sync(MPI_Request *request);
OMPI_DECLSPEC int OMPI_Startall_no_sync(int count, MPI_Request request_array[]);
