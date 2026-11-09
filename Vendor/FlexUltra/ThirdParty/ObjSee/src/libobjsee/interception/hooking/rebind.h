//
//  rebind.h
//  libobjsee
//
//  Created by Ethan Arbuckle on 11/30/24.
//

struct symbol_rebinding_t {
    const char * _Nonnull name;
    void * _Nonnull replacement;
    uint32_t num_symbols_rebound;
};

struct symbol_rebinding_diagnostics_t {
    uint32_t images_scanned;
    uint32_t images_eligible;
    uint32_t symbol_matches;
    uint32_t protection_failures;
    kern_return_t last_error;
};

struct symbol_rebinding_t * _Nullable hook_function(const char * _Nonnull symbol_to_hook,
                                                      void * _Nonnull replacement_func,
                                                      struct symbol_rebinding_diagnostics_t * _Nullable diagnostics);
