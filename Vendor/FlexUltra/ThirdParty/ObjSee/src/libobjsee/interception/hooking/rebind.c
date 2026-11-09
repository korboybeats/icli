//
//  rebind.c
//  libobjsee
//
//  Created by Ethan Arbuckle on 11/30/24.
//

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#include "tracer_internal.h"
#include "rebind.h"
#include "substrate_apis.h"

struct symbol_rebinding_internal_t {
    uint64_t slide;
    const char *string_table;
    struct nlist_64 *symbol_table;
    uint32_t *indirect_symbol_table;
};

static inline void *canonical_function_pointer_for_stub(void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}

static kern_return_t patch_symbol_stub_64(void *stub,
                                          uint32_t stub_size,
                                          void *replacement_func) {
    if (stub == NULL || replacement_func == NULL || stub_size < sizeof(uint32_t)) {
        return KERN_INVALID_ARGUMENT;
    }

    uintptr_t stub_address = (uintptr_t)stub;
    uintptr_t replacement_address = (uintptr_t)canonical_function_pointer_for_stub(replacement_func);
    intptr_t branch_delta = (intptr_t)replacement_address - (intptr_t)stub_address;

    // AArch64 B uses a signed imm26 scaled by 4, for a +/-128 MiB range.
    if ((branch_delta & 0x3) == 0 &&
        branch_delta >= -(1LL << 27) &&
        branch_delta < (1LL << 27)) {
        int64_t imm26 = branch_delta >> 2;
        uint32_t branch = 0x14000000u | ((uint32_t)imm26 & 0x03ffffffu);
        kern_return_t kr = objsee_MSHookMemory(stub, &branch, sizeof(branch));
        if (kr == KERN_SUCCESS && memcmp(stub, &branch, sizeof(branch)) == 0) {
            return KERN_SUCCESS;
        }
    }

    // arm64e authenticated stubs are 16 bytes. Replace the whole stub with an
    // absolute jump that does not depend on the authenticated GOT entry:
    //   ldr x16, #8
    //   br  x16
    //   .quad replacement
    if (stub_size >= 16) {
        struct {
            uint32_t ldr_x16_literal;
            uint32_t br_x16;
            uint64_t target;
        } patch = {
            .ldr_x16_literal = 0x58000050u,
            .br_x16 = 0xd61f0200u,
            .target = (uint64_t)replacement_address,
        };
        kern_return_t kr = objsee_MSHookMemory(stub, &patch, sizeof(patch));
        if (kr == KERN_SUCCESS && memcmp(stub, &patch, sizeof(patch)) == 0) {
            return KERN_SUCCESS;
        }
    }

    return KERN_FAILURE;
}

#define OBJC_MESSAGE_STUB_SIZE_64 32u
#define OBJC_MESSAGE_STUB_DISPATCH_OFFSET_64 8u

// Newer Apple linkers emit Objective-C sends through __TEXT,__objc_stubs
// rather than a normal S_SYMBOL_STUBS entry for objc_msgSend. Each 32-byte
// stub first loads its selector into x1, then dispatches through objc_msgSend.
// Preserve the selector load and replace only the dispatch tail.
static kern_return_t patch_objc_message_stub_64(void *stub,
                                                uint32_t stub_size,
                                                void *replacement_func) {
    if (stub == NULL || replacement_func == NULL ||
        stub_size < OBJC_MESSAGE_STUB_DISPATCH_OFFSET_64 + sizeof(uint32_t)) {
        return KERN_INVALID_ARGUMENT;
    }

    uint32_t *instructions = (uint32_t *)stub;
    // Require the canonical selector setup used by modern objc stubs:
    //   adrp x1, ...
    //   ldr  x1, [x1, #imm]
    if ((instructions[0] & 0x9f00001fu) != 0x90000001u ||
        (instructions[1] & 0xffc003ffu) != 0xf9400021u) {
        return KERN_FAILURE;
    }

    void *dispatch_site = (void *)((uintptr_t)stub + OBJC_MESSAGE_STUB_DISPATCH_OFFSET_64);
    uint32_t dispatch_space = stub_size - OBJC_MESSAGE_STUB_DISPATCH_OFFSET_64;
    return patch_symbol_stub_64(dispatch_site, dispatch_space, replacement_func);
}

static kern_return_t hook_objc_message_stubs_64(void *replacement_func,
                                                struct symbol_rebinding_internal_t *img_symbol_info,
                                                struct section_64 *stub_section,
                                                struct symbol_rebinding_diagnostics_t *diagnostics) {
    if (stub_section == NULL ||
        stub_section->size == 0 ||
        (stub_section->size % OBJC_MESSAGE_STUB_SIZE_64) != 0) {
        return KERN_INVALID_ARGUMENT;
    }

    uintptr_t stub_base = (uintptr_t)(stub_section->addr + img_symbol_info->slide);
    uint64_t num_entries = stub_section->size / OBJC_MESSAGE_STUB_SIZE_64;
    bool hooked = false;

    for (uint64_t i = 0; i < num_entries; i++) {
        void *stub = (void *)(stub_base + (i * OBJC_MESSAGE_STUB_SIZE_64));
        kern_return_t kr = patch_objc_message_stub_64(stub,
                                                      OBJC_MESSAGE_STUB_SIZE_64,
                                                      replacement_func);
        if (kr != KERN_SUCCESS) {
            if (diagnostics != NULL && kr != KERN_FAILURE) {
                diagnostics->last_error = kr;
            }
            continue;
        }

        hooked = true;
        if (diagnostics != NULL) {
            diagnostics->symbol_matches++;
        }
    }

    return hooked ? KERN_SUCCESS : KERN_FAILURE;
}

static kern_return_t hook_symbol_stubs_64(const char *symbol_to_hook,
                                          void *replacement_func,
                                          struct symbol_rebinding_internal_t *img_symbol_info,
                                          struct section_64 *stub_section,
                                          struct symbol_rebinding_diagnostics_t *diagnostics) {
    if (stub_section == NULL || stub_section->reserved2 == 0) {
        return KERN_INVALID_ARGUMENT;
    }

    uint32_t *indirect_symbols = (uint32_t *)((uintptr_t)img_symbol_info->indirect_symbol_table +
                                               stub_section->reserved1 * sizeof(uint32_t));
    uintptr_t stub_base = (uintptr_t)(stub_section->addr + img_symbol_info->slide);
    uint64_t num_entries = stub_section->size / stub_section->reserved2;
    bool hooked = false;

    for (uint64_t i = 0; i < num_entries; i++) {
        uint32_t idx = indirect_symbols[i];
        if (idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) {
            continue;
        }

        struct nlist_64 *sym = img_symbol_info->symbol_table + idx;
        const char *symbol_name = img_symbol_info->string_table + sym->n_un.n_strx;
        if (symbol_name == NULL || symbol_name[0] == '\0' || strcmp(&symbol_name[1], symbol_to_hook) != 0) {
            continue;
        }

        if (diagnostics != NULL) {
            diagnostics->symbol_matches++;
        }

        void *stub = (void *)(stub_base + (i * stub_section->reserved2));
        kern_return_t kr = patch_symbol_stub_64(stub,
                                                stub_section->reserved2,
                                                replacement_func);
        if (kr != KERN_SUCCESS) {
            if (diagnostics != NULL) {
                diagnostics->last_error = kr;
            }
            continue;
        }

        hooked = true;
    }

    return hooked ? KERN_SUCCESS : KERN_FAILURE;
}

static kern_return_t make_symbol_bindings_writable(void *bindings, size_t size) {
    if (bindings == NULL || size == 0) {
        return KERN_INVALID_ARGUMENT;
    }

    size_t page_size = (size_t)getpagesize();
    uintptr_t start = (uintptr_t)bindings & ~(page_size - 1);
    uintptr_t end = ((uintptr_t)bindings + size + page_size - 1) & ~(page_size - 1);
    return vm_protect(mach_task_self(),
                      (vm_address_t)start,
                      (vm_size_t)(end - start),
                      0,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}

struct dyld_interpose_tuple_compat {
    const void *replacement;
    const void *replacee;
};

typedef void (*dyld_dynamic_interpose_fn)(const struct mach_header *mh,
                                          const struct dyld_interpose_tuple_compat tuples[],
                                          size_t count);

static uint64_t replacement_binding_value_64(void *replacement_func,
                                             uint64_t *binding_slot,
                                             const struct section_64 *symbol_section) {
#if __has_feature(ptrauth_calls)
    // arm64e imports executable symbols through __auth_got using the IA key,
    // address diversity, and a zero discriminator. A raw function address in
    // one of these slots will fail authentication when the stub branches
    // through it, so sign the replacement for the address of this exact slot.
    if (strcmp(symbol_section->sectname, "__auth_got") == 0) {
        void *unsigned_replacement = ptrauth_strip(replacement_func, ptrauth_key_function_pointer);
        ptrauth_extra_data_t discriminator = ptrauth_blend_discriminator(binding_slot, 0);
        return (uint64_t)ptrauth_sign_unauthenticated(unsigned_replacement,
                                                      ptrauth_key_asia,
                                                      discriminator);
    }
#endif
    return (uint64_t)replacement_func;
}


kern_return_t rebind_symbol_64(const char *symbol_to_hook,
                               void *replacement_func,
                               struct symbol_rebinding_internal_t *img_symbol_info,
                               struct section_64 *symbol_section,
                               struct symbol_rebinding_diagnostics_t *diagnostics) {
    uint32_t *indirect_symbols = (uint32_t *)((uintptr_t)img_symbol_info->indirect_symbol_table + symbol_section->reserved1 * sizeof(uint32_t));
    uint64_t *sym_bindings = (uint64_t *)(symbol_section->addr + img_symbol_info->slide);
    uint64_t num_entries = symbol_section->size / sizeof(uint64_t);
    
    bool rebound = false;
    bool made_writable = false;
    for (uint64_t i = 0; i < num_entries; i++) {
        uint32_t idx = indirect_symbols[i];
        if (idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) {
            continue;
        }
        
        struct nlist_64 *sym = (struct nlist_64 *)img_symbol_info->symbol_table + idx;
        uint32_t string_table_offset = sym->n_un.n_strx;
        const char *symbol_name = (const char *)img_symbol_info->string_table + string_table_offset;
        if (symbol_name == NULL || strlen(symbol_name) < 1 || strcmp(&symbol_name[1], symbol_to_hook) != 0) {
            continue;
        }

        if (diagnostics != NULL) {
            diagnostics->symbol_matches++;
        }
        
        if (!made_writable) {
            kern_return_t kr = make_symbol_bindings_writable(sym_bindings, symbol_section->size);
            if (kr != KERN_SUCCESS) {
                if (diagnostics != NULL) {
                    diagnostics->protection_failures++;
                    diagnostics->last_error = kr;
                }
                return kr;
            }
            made_writable = true;
        }

        sym_bindings[i] = replacement_binding_value_64(replacement_func, &sym_bindings[i], symbol_section);
        rebound = true;
    }

    return rebound ? KERN_SUCCESS : KERN_FAILURE;
}

kern_return_t rebind_symbol_32(const char *symbol_to_hook,
                               void *replacement_func,
                               struct symbol_rebinding_internal_t *img_symbol_info,
                               struct section *symbol_section,
                               struct symbol_rebinding_diagnostics_t *diagnostics) {
    uint32_t *indirect_symbols = (uint32_t *)((uintptr_t)img_symbol_info->indirect_symbol_table + symbol_section->reserved1 * sizeof(uint32_t));
    uint32_t *sym_bindings = (uint32_t *)(symbol_section->addr + img_symbol_info->slide);
    uint32_t num_entries = symbol_section->size / sizeof(uint32_t);
    
    bool rebound = false;
    bool made_writable = false;
    for (uint32_t i = 0; i < num_entries; i++) {
        uint32_t idx = indirect_symbols[i];
        if (idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) {
            continue;
        }
        
        struct nlist *sym = (struct nlist *)img_symbol_info->symbol_table + idx;
        uint32_t string_table_offset = sym->n_un.n_strx;
        const char *symbol_name = (const char *)img_symbol_info->string_table + string_table_offset;
        if (symbol_name == NULL || strlen(symbol_name) < 1 || strcmp(&symbol_name[1], symbol_to_hook) != 0) {
            continue;
        }

        if (diagnostics != NULL) {
            diagnostics->symbol_matches++;
        }
        
        if (!made_writable) {
            kern_return_t kr = make_symbol_bindings_writable(sym_bindings, symbol_section->size);
            if (kr != KERN_SUCCESS) {
                if (diagnostics != NULL) {
                    diagnostics->protection_failures++;
                    diagnostics->last_error = kr;
                }
                return kr;
            }
            made_writable = true;
        }

        sym_bindings[i] = (uint32_t)(uintptr_t)replacement_func;
        rebound = true;
    }

    return rebound ? KERN_SUCCESS : KERN_FAILURE;
}

void for_load_command_in_mach_header(struct mach_header *mh, void (^callback)(struct load_command *lc)) {
    if (mh == NULL || callback == NULL) {
        return;
    }
    
    bool is_64bit = (mh->magic == MH_MAGIC_64 || mh->magic == MH_CIGAM_64);
    size_t mh_struct_size = is_64bit ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    
    struct load_command *lc = (struct load_command *)((mach_vm_address_t)mh + mh_struct_size);
    for (int command = 0; command < mh->ncmds; command++) {
        
        callback(lc);
        lc = (struct load_command *)((mach_vm_address_t)lc + lc->cmdsize);
    }
}

kern_return_t hook_function_in_mach_header(const char *symbol_to_hook,
                                            void *replacement_func,
                                            struct mach_header *mh,
                                            struct symbol_rebinding_diagnostics_t *diagnostics) {
    if (mh == NULL || symbol_to_hook == NULL || replacement_func == NULL) {
        return TRACER_ERROR_INVALID_ARGUMENT;
    }
    
    Dl_info info;
    if (dladdr((void *)mh, &info) == 0) {
        return TRACER_ERROR_INVALID_ARGUMENT;
    }

    Dl_info replacement_info = {0};
    bool replacement_image_known = dladdr(replacement_func, &replacement_info) != 0;
    bool patch_modern_objc_stubs = strcmp(symbol_to_hook, "objc_msgSend") == 0 &&
                                   (mh == _dyld_get_image_header(0) ||
                                    (replacement_image_known && replacement_info.dli_fbase == (void *)mh));
    
    bool is_64bit = (mh->magic == MH_MAGIC_64 || mh->magic == MH_CIGAM_64);
    
    struct symbol_rebinding_internal_t *img_symbol_info = (struct symbol_rebinding_internal_t *)malloc(sizeof(struct symbol_rebinding_internal_t));
    if (img_symbol_info == NULL) {
        return KERN_NO_SPACE;
    }
    
    __block struct symtab_command *symbol_table_cmd = NULL;
    __block struct dysymtab_command *dynamic_symbol_table_cmd = NULL;
    __block uint64_t linkedit_vmaddr = 0;
    __block uint64_t linkedit_fileoff = 0;
    __block uint64_t text_vmaddr = 0;
    __block bool found_linkedit = false;
    __block bool found_text = false;
    
    for_load_command_in_mach_header(mh, ^(struct load_command *lc) {
        switch (lc->cmd) {
                
            case LC_DYSYMTAB:
                dynamic_symbol_table_cmd = (struct dysymtab_command *)lc;
                break;
                
            case LC_SYMTAB:
                symbol_table_cmd = (struct symtab_command *)lc;
                break;
                
            case LC_SEGMENT_64: {
                
                struct segment_command_64 *seg = (struct segment_command_64 *)lc;
                if (strcmp(seg->segname, SEG_TEXT) == 0) {
                    text_vmaddr = seg->vmaddr;
                    found_text = true;
                } else if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                    linkedit_vmaddr = seg->vmaddr;
                    linkedit_fileoff = seg->fileoff;
                    found_linkedit = true;
                }
                break;
            }
                
            case LC_SEGMENT: {
                struct segment_command *seg = (struct segment_command *)lc;
                if (strcmp(seg->segname, SEG_TEXT) == 0) {
                    text_vmaddr = seg->vmaddr;
                    found_text = true;
                } else if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                    linkedit_vmaddr = seg->vmaddr;
                    linkedit_fileoff = seg->fileoff;
                    found_linkedit = true;
                }
                break;
            }
                
            default:
                break;
        }
    });

    if (!found_linkedit || symbol_table_cmd == NULL || dynamic_symbol_table_cmd == NULL || !found_text) {
        free(img_symbol_info);
        return KERN_FAILURE;
    }
    
    if (dynamic_symbol_table_cmd->nindirectsyms == 0) {
        free(img_symbol_info);
        return KERN_FAILURE;
    }

    if (diagnostics != NULL) {
        diagnostics->images_eligible++;
    }
    
    img_symbol_info->slide = (intptr_t)mh - text_vmaddr;
    img_symbol_info->string_table = (void *)(linkedit_vmaddr + symbol_table_cmd->stroff - linkedit_fileoff + img_symbol_info->slide);
    img_symbol_info->symbol_table = (void *)(linkedit_vmaddr + symbol_table_cmd->symoff - linkedit_fileoff + img_symbol_info->slide);
    img_symbol_info->indirect_symbol_table = (void *)(linkedit_vmaddr + dynamic_symbol_table_cmd->indirectsymoff - linkedit_fileoff + img_symbol_info->slide);

    if (is_64bit) {
        __block bool hooked_stub = false;
        for_load_command_in_mach_header(mh, ^(struct load_command *lc) {
            if (lc->cmd != LC_SEGMENT_64) {
                return;
            }

            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            for (uint32_t i = 0; i < seg->nsects; i++) {
                struct section_64 *sect = (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64)) + i;

                if (patch_modern_objc_stubs &&
                    strcmp(sect->segname, SEG_TEXT) == 0 &&
                    strcmp(sect->sectname, "__objc_stubs") == 0) {
                    if (hook_objc_message_stubs_64(replacement_func,
                                                   img_symbol_info,
                                                   sect,
                                                   diagnostics) == KERN_SUCCESS) {
                        hooked_stub = true;
                    }
                    continue;
                }

                if ((sect->flags & SECTION_TYPE) != S_SYMBOL_STUBS) {
                    continue;
                }

                if (hook_symbol_stubs_64(symbol_to_hook,
                                         replacement_func,
                                         img_symbol_info,
                                         sect,
                                         diagnostics) == KERN_SUCCESS) {
                    hooked_stub = true;
                }
            }
        });

        if (hooked_stub) {
            free(img_symbol_info);
            return KERN_SUCCESS;
        }
    }
    
    __block struct section_64 *lazy_symbol_section_64 = NULL;
    __block struct section_64 *non_lazy_symbol_section_64 = NULL;
    __block struct section *lazy_symbol_section_32 = NULL;
    __block struct section *non_lazy_symbol_section_32 = NULL;
    
    for_load_command_in_mach_header(mh, ^(struct load_command *lc) {
        if (lc->cmd == LC_SEGMENT) {
            struct segment_command *seg = (struct segment_command *)lc;
            if (strcmp(seg->segname, SEG_DATA) != 0 && strcmp(seg->segname, "__DATA_CONST") != 0) {
                return;
            }
            
            for (uint32_t i = 0; i < seg->nsects; i++) {
                struct section *sect = (struct section *)((uintptr_t)seg + sizeof(struct segment_command)) + i;
                switch (sect->flags & SECTION_TYPE) {
                    case S_LAZY_SYMBOL_POINTERS:
                        lazy_symbol_section_32 = sect;
                        break;
                        
                    case S_NON_LAZY_SYMBOL_POINTERS:
                        non_lazy_symbol_section_32 = sect;
                        break;
                        
                    default:
                        break;
                }
            }
        }
        else if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_DATA) != 0 && strcmp(seg->segname, "__DATA_CONST") != 0) {
                return;
            }
            
            for (uint32_t i = 0; i < seg->nsects; i++) {
                struct section_64 *sect = (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64)) + i;
                switch (sect->flags & SECTION_TYPE) {
                    case S_LAZY_SYMBOL_POINTERS:
                        lazy_symbol_section_64 = sect;
                        break;
                        
                    case S_NON_LAZY_SYMBOL_POINTERS:
                        non_lazy_symbol_section_64 = sect;
                        break;
                        
                    default:
                        break;
                }
            }
        }
    });
    
    kern_return_t ret = KERN_FAILURE;
    if (is_64bit) {
        if (lazy_symbol_section_64 != NULL) {
            ret = rebind_symbol_64(symbol_to_hook, replacement_func, img_symbol_info, lazy_symbol_section_64, diagnostics);
        }
        if (ret != KERN_SUCCESS && non_lazy_symbol_section_64 != NULL) {
            ret = rebind_symbol_64(symbol_to_hook, replacement_func, img_symbol_info, non_lazy_symbol_section_64, diagnostics);
        }
    }
    else {
        if (lazy_symbol_section_32 != NULL) {
            ret = rebind_symbol_32(symbol_to_hook, replacement_func, img_symbol_info, lazy_symbol_section_32, diagnostics);
        }
        if (ret != KERN_SUCCESS && non_lazy_symbol_section_32 != NULL) {
            ret = rebind_symbol_32(symbol_to_hook, replacement_func, img_symbol_info, non_lazy_symbol_section_32, diagnostics);
        }
    }
    
    free(img_symbol_info);
    return ret;
}

struct symbol_rebinding_t * _Nullable hook_function(const char *symbol_to_hook,
                                                     void *replacement_func,
                                                     struct symbol_rebinding_diagnostics_t *diagnostics) {
    if (diagnostics != NULL) {
        memset(diagnostics, 0, sizeof(*diagnostics));
        diagnostics->last_error = KERN_FAILURE;
    }

    if (symbol_to_hook == NULL || replacement_func == NULL) {
        if (diagnostics != NULL) {
            diagnostics->last_error = KERN_INVALID_ARGUMENT;
        }
        return NULL;
    }

    void *function_to_hook_ptr = dlsym(RTLD_DEFAULT, symbol_to_hook);
    if (function_to_hook_ptr == NULL) {
        return NULL;
    }

    int hook_count = 0;
    for (int i = 0; i < _dyld_image_count(); i++) {
        struct mach_header *mh = (struct mach_header *)_dyld_get_image_header(i);
        if (diagnostics != NULL) {
            diagnostics->images_scanned++;
        }
        kern_return_t result = hook_function_in_mach_header(symbol_to_hook, replacement_func, mh, diagnostics);
        if (result == KERN_SUCCESS) {
            hook_count++;
        }
        else if (diagnostics != NULL && diagnostics->last_error == KERN_FAILURE && result != KERN_FAILURE) {
            diagnostics->last_error = result;
        }
    }
    
    if (hook_count == 0) {
        return NULL;
    }
    
    // Inform the caller of the number of symbols rebound
    struct symbol_rebinding_t *rebinding = (struct symbol_rebinding_t *)malloc(sizeof(struct symbol_rebinding_t));
    rebinding->name = symbol_to_hook;
    rebinding->replacement = replacement_func;
    rebinding->num_symbols_rebound = hook_count;
    if (diagnostics != NULL) {
        diagnostics->last_error = KERN_SUCCESS;
    }
    return rebinding;
}
