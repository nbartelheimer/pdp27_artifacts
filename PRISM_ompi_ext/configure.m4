# -*- shell-script -*-
#
# Copyright (c) 2004-2009 The Trustees of Indiana University.
#                         All rights reserved.
# Copyright (c) 2012-2015 Cisco Systems, Inc.  All rights reserved.
# Copyright (c) 2019      FUJITSU LIMITED.  All rights reserved.
# $COPYRIGHT$
#
# Additional copyrights may follow
#
# $HEADER$
#

# OMPI_MPIEXT_persistent_CONFIG([action-if-found], [action-if-not-found])
# -----------------------------------------------------------
AC_DEFUN([OMPI_MPIEXT_persistent_CONFIG],[
    AC_CONFIG_FILES([ompi/mpiext/persistent/Makefile])
    AC_CONFIG_FILES([ompi/mpiext/persistent/c/Makefile])

    # If your extension can build, run $1.  Otherwise, run $2.  For
    # the purposes of this persistent, we don't want it to build in most
    # cases.  So only build if someone specifies an --enable-mpi-ext
    # value that contains the token "persistent".
    AS_IF([test "$ENABLE_persistent" = "1" || \
           test "$ENABLE_EXT_ALL" = "1"],
          [$1],
          [$2])
])

# only need to set this if the component needs init/finalize hooks
AC_DEFUN([OMPI_MPIEXT_persistent_NEED_INIT], [1])

# By default, mpiext_persistent_mpifh.h is included in the source file
# of the mpi_ext module. To disable it, define this macro as 0.
# AC_DEFUN([OMPI_MPIEXT_persistent_INCLUDE_MPIFH_IN_USEMPI], [0])

# By default, mpiext_persistent_mpifh.h is included in the source file
# of the mpi_f08_ext module. To disable it, define this macro as 0.
# AC_DEFUN([OMPI_MPIEXT_persistent_INCLUDE_MPIFH_IN_USEMPIF08], [0])

# By default, $build_dir/ompi/mpiext/persistent/c/libmpiext_persistent_c.la
# (Libtool archive) is added to the dependency list of libmpi.la.
# This rule is the same for mpif-h and use-mpi-f08 bindings.
# However, the ar command of macOS refuses to create an archive file
# which does not contain any object files. If your extension has no
# object files, i.e. only header files, define this macro as 0 so that
# the *.la files are not added to the dependency lists.

# NOTE: This is currently a single macro for the entire MPI extension.
# I.e., your extension either has a library for each binding, or it has *no*
# libraries for any of the bindings.  If finer-grained control is needed
# someday, we may need to split this into multiple macros.
# AC_DEFUN([OMPI_MPIEXT_persistent_HAVE_OBJECT], [1])

# This is a hook that runs after the CONFIG macro and after the
# configure system decides if this extension will be built (such
# as if it was disabled by configure option).  This is a great
# place to put any globally-visible AC_DEFINE or AM_CONDITIONAL
# macros that are based on this component building.
AC_DEFUN([OMPI_MPIEXT_persistent_POST_CONFIG], [
  opal_show_verbose "persistent component build result: $1"
])
