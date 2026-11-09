#pragma once
#include <mach/mach.h>
// ObjSee's user-space Mach API declaration uses vm_map_t, an alias omitted
// from current iPhoneOS public headers. A user-space VM map is a Mach port.
typedef mach_port_t vm_map_t;
