#ifndef VT_AV1_DECODE_H
#define VT_AV1_DECODE_H

#include <stddef.h>
#include <stdint.h>

// Native VideoToolbox AV1 decoder.
//
// FFmpeg before 8.0 has no av1_videotoolbox hwaccel, and the pinned CI FFmpeg
// (7.1) cannot hardware decode AV1 on macOS. VideoToolbox itself supports AV1
// decode on Apple Silicon M3 and later, so this module talks to
// VTDecompressionSession directly.
//
// The decoder is created lazily: the decompression session is (re)created
// whenever a new sequence header OBU arrives, so resolution changes are
// handled transparently.

#define VT_AV1_NUM_DATA_POINTERS 8

// Same signature as RamDecodeCallback in ffmpeg_ram_ffi.h, with its own name
// to avoid clashing with the enum-flavored typedef in ffmpeg_ram_decode.cpp.
typedef void (*VTAv1DecodeCallback)(const void *obj, int width, int height,
                                    int pixfmt,
                                    int linesize[VT_AV1_NUM_DATA_POINTERS],
                                    uint8_t *data[VT_AV1_NUM_DATA_POINTERS],
                                    int key);

// Returns NULL when AV1 hardware decode is not available.
// nv12_pixfmt / yuv420p_pixfmt are the AVPixelFormat integer values reported
// to the callback, kept as parameters so this file needs no FFmpeg headers.
void *vt_av1_decoder_create(VTAv1DecodeCallback callback, int nv12_pixfmt,
                            int yuv420p_pixfmt);

// Decode one packet (a low-overhead AV1 OBU stream, one frame per packet).
// Returns 0 when at least one frame was delivered to the callback, -1
// otherwise. Mirrors ffmpeg_ram_decode semantics.
int vt_av1_decoder_decode(void *decoder, const uint8_t *data, int length,
                          const void *obj);

void vt_av1_decoder_destroy(void *decoder);

#endif // VT_AV1_DECODE_H
