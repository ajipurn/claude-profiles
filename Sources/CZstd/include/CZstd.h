/* Minimal Swift-facing surface of the vendored zstd decoder (lib/, v1.5.7).
 * Only this header is exported to Swift; the .c files include lib/zstd.h
 * directly, so these declarations never meet the real ones in one TU.
 * Streaming API because Chromium cache bodies are streamed frames with no
 * up-front content size. */
#ifndef CZSTD_H
#define CZSTD_H

#include <stddef.h>

typedef struct ZSTD_DCtx_s ZSTD_DStream;

ZSTD_DStream* ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream* zds);
size_t ZSTD_initDStream(ZSTD_DStream* zds);

typedef struct { const void* src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void* dst; size_t size; size_t pos; } ZSTD_outBuffer;

size_t ZSTD_decompressStream(ZSTD_DStream* zds, ZSTD_outBuffer* output, ZSTD_inBuffer* input);
unsigned ZSTD_isError(size_t code);

#endif
