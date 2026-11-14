#ifndef VISTARA_PRINTER_H
#define VISTARA_PRINTER_H

// Printing (docs/DESIGN.md, Printing): one printer, "Vistara", with Windows'
// Microsoft Print to PDF driver, served by a printer backend of Vistara's own
// instead of CUPS. Each job is written to a file in the session's print
// folder (vistara_print_spool) and handed to the app when the remote computer
// closes it.
//
// FreeRDP's printer channel loads a backend from the driver name's
// ":<backend>" suffix and passes it nothing about the session, so the device
// is added with the driver name "Microsoft Print to PDF:vistara-<id>", and the
// backend finds the session's spool by that id. The remote computer is told
// the driver name without the suffix.

#include "CFreeRDP.h"

#include <freerdp/client/printer.h>

/// The backend's name as FreeRDP's add-in loader asks for it, before "-<id>".
#define VISTARA_PRINTER_SUBSYSTEM "vistara"
#define VISTARA_PRINTER_NAME "Vistara"
#define VISTARA_PRINTER_DRIVER "Microsoft Print to PDF"

/// The largest document accepted: 512 MB.
#define VISTARA_PRINT_LIMIT (512ull * 1024ull * 1024ull)

/// The printer backend entry point, which FreeRDP's add-in loader finds
/// under the printer channel and a subsystem starting with VISTARA_PRINTER_SUBSYSTEM.
UINT VCAPITYPE vistara_printer_backend_entry(void *driver);

/// Calls `notify` with `context`, on whichever thread, whenever a document ended.
void vistara_print_spool_set_notify(vistara_print_spool *spool, void (*notify)(void *), void *context);

/// Makes `spool` the one for the printer device whose driver name ends in
/// "vistara-<id>", until unregistered. Returns the id, or 0 when full.
uint32_t vistara_printer_register(vistara_print_spool *spool);
void vistara_printer_unregister(uint32_t id);

#endif
