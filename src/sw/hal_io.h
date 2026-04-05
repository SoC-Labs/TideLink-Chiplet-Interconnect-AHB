/*-----------------------------------------------------------------------------
 * HAL I/O — Test-Mode Macro Override
 *
 * When building C drivers as a host-native shared library for cocotb
 * driver-in-the-loop testing, this header redefines the CMSIS-style
 * access qualifiers to remove volatile.
 *
 * Usage: compile with  -DHAL_TEST_MODE -include hal_io.h
 *---------------------------------------------------------------------------*/

#ifndef HAL_IO_H
#define HAL_IO_H

#ifdef HAL_TEST_MODE
#define __IO  /* non-volatile */
#define __I   /* non-volatile */
#define __O   /* non-volatile */
#endif

#endif /* HAL_IO_H */
