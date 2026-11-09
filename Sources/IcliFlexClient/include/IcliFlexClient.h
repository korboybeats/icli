#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef char *(*ICLIFlexTransport)(const char *request);
int32_t icli_flex_cli(int argc, const char *const *argv, ICLIFlexTransport transport);
int32_t icli_flex_mcp(ICLIFlexTransport transport);
const char *icli_flex_build_id(void);
char *icli_flex_catalog_json(void);
char *icli_flex_error_json(const char *id, const char *code, const char *message, const char *operation);
char *icli_flex_input_arguments_json(const char *request);
int32_t icli_flex_receive_timeout(const char *operation);
#ifdef __cplusplus
}
#endif
