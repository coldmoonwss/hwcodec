// Native VideoToolbox AV1 decoder, see vt_av1_decode.h.
//
// Bitstream contract (verified on Apple Silicon):
// - av1C: 4-byte AV1CodecConfigurationRecord header followed by the sequence
//   header OBU exactly as it appears in the stream (leb128 size included).
// - sample: concatenation of the frame's OBUs as-is (leb128 size included),
//   temporal delimiter OBUs removed.

#include "vt_av1_decode.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <string>
#include <vector>

#define LOG_MODULE "VT_AV1_DEC"
#include "log.h"

// kCMVideoCodecType_AV1 is only declared in the macOS 13+ SDK headers.
// It is a FourCC enum constant ('av01'), so a plain fallback is safe.
#ifndef kCMVideoCodecType_AV1
#define kCMVideoCodecType_AV1 ((CMVideoCodecType) 'av01')
#endif

namespace {

// ---------------- bit reader ----------------
struct BitReader {
  const uint8_t *p;
  size_t len; // bytes
  size_t bit;
  BitReader(const uint8_t *p_, size_t len_) : p(p_), len(len_), bit(0) {}
  uint32_t f(int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
      size_t byte = bit >> 3;
      int off = 7 - (int)(bit & 7);
      v = (v << 1) | (((byte < len ? p[byte] : 0) >> off) & 1);
      bit++;
    }
    return v;
  }
};

struct SeqInfo {
  int seq_profile;
  int seq_level_idx;
  int seq_tier;
  int high_bitdepth;
  int twelve_bit;
  int mono_chrome;
  int subsampling_x;
  int subsampling_y;
  int chroma_sample_position;
  int initial_display_delay_present_flag;
  int initial_display_delay_minus_1;
  int max_frame_width;
  int max_frame_height;
  SeqInfo()
      : seq_profile(0), seq_level_idx(0), seq_tier(0), high_bitdepth(0),
        twelve_bit(0), mono_chrome(0), subsampling_x(1), subsampling_y(1),
        chroma_sample_position(0), initial_display_delay_present_flag(0),
        initial_display_delay_minus_1(0), max_frame_width(0),
        max_frame_height(0) {}
};

// Parses the fields needed for av1C and the coded size.
// data/len: sequence header OBU payload (OBU header excluded).
static bool parse_sequence_header(const uint8_t *data, size_t len,
                                  SeqInfo &si) {
  BitReader b(data, len);
  si.seq_profile = b.f(3);
  b.f(1); // still_picture
  int reduced_still_picture_header = b.f(1);
  int decoder_model_info_present_flag = 0;
  int buffer_delay_length_minus_1 = 0;
  if (reduced_still_picture_header) {
    si.seq_level_idx = b.f(5);
  } else {
    int timing_info_present_flag = b.f(1);
    if (timing_info_present_flag) {
      b.f(32); // num_units_in_display_tick
      b.f(32); // time_scale
      int equal_picture_interval = b.f(1);
      if (equal_picture_interval) {
        // uvlc num_ticks_per_picture_minus_1
        int leadingZeros = 0;
        while (b.f(1) == 0 && leadingZeros < 32)
          leadingZeros++;
        if (leadingZeros == 32)
          return false;
        b.f(leadingZeros);
      }
      decoder_model_info_present_flag = b.f(1);
      if (decoder_model_info_present_flag) {
        buffer_delay_length_minus_1 = b.f(5);
        b.f(32); // num_units_in_decoding_tick
        b.f(5);  // buffer_removal_time_length_minus_1
        b.f(5);  // frame_presentation_time_length_minus_1
      }
    }
    si.initial_display_delay_present_flag = b.f(1);
    int operating_points_cnt_minus_1 = b.f(5);
    for (int i = 0; i <= operating_points_cnt_minus_1; i++) {
      b.f(12); // operating_point_idc
      int level = b.f(5);
      int tier = 0;
      if (level > 7)
        tier = b.f(1);
      if (i == 0) {
        si.seq_level_idx = level;
        si.seq_tier = tier;
      }
      if (decoder_model_info_present_flag) {
        int decoder_model_present_for_this_op = b.f(1);
        if (decoder_model_present_for_this_op) {
          int n = buffer_delay_length_minus_1 + 1;
          b.f(n); // decoder_buffer_delay
          b.f(n); // encoder_buffer_delay
          b.f(1); // low_delay_mode_flag
        }
      }
      if (si.initial_display_delay_present_flag) {
        int idd_present = b.f(1);
        if (idd_present) {
          int v = b.f(4);
          if (i == 0)
            si.initial_display_delay_minus_1 = v;
        }
      }
    }
  }
  int frame_width_bits_minus_1 = b.f(4);
  int frame_height_bits_minus_1 = b.f(4);
  si.max_frame_width = (int)b.f(frame_width_bits_minus_1 + 1) + 1;
  si.max_frame_height = (int)b.f(frame_height_bits_minus_1 + 1) + 1;
  if (!reduced_still_picture_header) {
    int frame_id_numbers_present_flag = b.f(1);
    if (frame_id_numbers_present_flag) {
      b.f(4); // delta_frame_id_length_minus_2
      b.f(3); // additional_frame_id_length_minus_1
    }
  }
  b.f(1); // use_128x128_superblock
  b.f(1); // enable_filter_intra
  b.f(1); // enable_intra_edge_filter
  if (!reduced_still_picture_header) {
    b.f(1); // enable_interintra_compound
    b.f(1); // enable_masked_compound
    b.f(1); // enable_warped_motion
    b.f(1); // enable_dual_filter
    int enable_order_hint = b.f(1);
    if (enable_order_hint) {
      b.f(1); // enable_jnt_comp
      b.f(1); // enable_ref_frame_mvs
    }
    int seq_choose_screen_content_tools = b.f(1);
    int seq_force_screen_content_tools = 2; // SELECT_SCREEN_CONTENT_TOOLS
    if (!seq_choose_screen_content_tools)
      seq_force_screen_content_tools = b.f(1);
    if (seq_force_screen_content_tools > 0) {
      int seq_choose_integer_mv = b.f(1);
      if (!seq_choose_integer_mv)
        b.f(1); // seq_force_integer_mv
    }
    if (enable_order_hint)
      b.f(3); // order_hint_bits_minus_1
  }
  b.f(1); // enable_superres
  b.f(1); // enable_cdef
  b.f(1); // enable_restoration
  // color_config
  si.high_bitdepth = b.f(1);
  if (si.seq_profile == 2 && si.high_bitdepth)
    si.twelve_bit = b.f(1);
  if (si.seq_profile == 1) {
    si.mono_chrome = 0;
  } else {
    si.mono_chrome = b.f(1);
  }
  int color_primaries = 2;           // CP_UNSPECIFIED
  int transfer_characteristics = 2;  // TC_UNSPECIFIED
  int matrix_coefficients = 2;       // MC_UNSPECIFIED
  if (!si.mono_chrome) {
    int color_description_present_flag = b.f(1);
    if (color_description_present_flag) {
      color_primaries = b.f(8);
      transfer_characteristics = b.f(8);
      matrix_coefficients = b.f(8);
    }
  }
  if (si.mono_chrome) {
    si.subsampling_x = 1;
    si.subsampling_y = 1;
    si.chroma_sample_position = 0; // CSP_UNKNOWN
  } else if (color_primaries == 1 /* CP_BT709 */ &&
             transfer_characteristics == 13 /* TC_SRGB */ &&
             matrix_coefficients == 0 /* MC_IDENTITY */) {
    si.subsampling_x = 0;
    si.subsampling_y = 0;
  } else {
    if (si.seq_profile == 0) {
      si.subsampling_x = 1;
      si.subsampling_y = 1;
    } else if (si.seq_profile == 1) {
      si.subsampling_x = 0;
      si.subsampling_y = 0;
    } else {
      if (si.twelve_bit) {
        si.subsampling_x = b.f(1);
        si.subsampling_y = si.subsampling_x ? b.f(1) : 0;
      } else {
        si.subsampling_x = 1;
        si.subsampling_y = 0;
      }
    }
    if (si.subsampling_x && si.subsampling_y)
      si.chroma_sample_position = b.f(2);
  }
  if (b.bit / 8 > len)
    return false;
  return true;
}

// ---------------- OBU splitting ----------------
enum ObuType {
  OBU_SEQUENCE_HEADER = 1,
  OBU_TEMPORAL_DELIMITER = 2,
  OBU_FRAME = 6,
};

struct Obu {
  int type;
  const uint8_t *raw; // header (+ extension + leb128 size) + payload
  size_t raw_len;
  const uint8_t *payload; // after header/extension/leb128 size
  size_t payload_len;
};

// Splits a low-overhead OBU stream. An OBU without a size field extends to
// the end of the packet.
static std::vector<Obu> split_obus(const uint8_t *data, size_t len) {
  std::vector<Obu> out;
  size_t pos = 0;
  while (pos < len) {
    uint8_t hdr = data[pos];
    int type = (hdr >> 3) & 0xF;
    int ext = (hdr >> 2) & 1;
    int has_size = (hdr >> 1) & 1;
    size_t header_len = 1 + (ext ? 1 : 0);
    if (pos + header_len > len)
      break;
    size_t payload_len = 0;
    size_t size_field_len = 0;
    if (has_size) {
      size_t p = pos + header_len;
      uint64_t v = 0;
      int i = 0;
      for (; i < 8 && p < len; i++, p++) {
        v |= (uint64_t)(data[p] & 0x7F) << (i * 7);
        if (!(data[p] & 0x80))
          break;
      }
      if (p >= len)
        break;
      size_field_len = i + 1;
      payload_len = (size_t)v;
      if (pos + header_len + size_field_len + payload_len > len)
        break;
    } else {
      payload_len = len - pos - header_len;
    }
    Obu o;
    o.type = type;
    o.raw = data + pos;
    o.raw_len = header_len + size_field_len + payload_len;
    o.payload = data + pos + header_len + size_field_len;
    o.payload_len = payload_len;
    out.push_back(o);
    pos += o.raw_len;
  }
  return out;
}

// ---------------- decoder ----------------
class VTAv1Decoder {
public:
  VTDecompressionSessionRef session_;
  CMVideoFormatDescriptionRef fmt_;
  VTAv1DecodeCallback callback_;
  int nv12_pixfmt_;
  int yuv420p_pixfmt_;
  std::string seq_obu_; // current sequence header OBU (as-is, with leb128)
  int width_;
  int height_;
  // per-decode-call output state
  const void *cur_obj_;
  int cur_key_;
  int frames_out_;
  OSStatus cb_status_;

  VTAv1Decoder(VTAv1DecodeCallback callback, int nv12_pixfmt, int yuv420p_pixfmt)
      : session_(NULL), fmt_(NULL), callback_(callback),
        nv12_pixfmt_(nv12_pixfmt), yuv420p_pixfmt_(yuv420p_pixfmt), width_(0),
        height_(0), cur_obj_(NULL), cur_key_(0), frames_out_(0), cb_status_(0) {
  }

  ~VTAv1Decoder() { destroy_session(); }

  void destroy_session() {
    if (session_) {
      VTDecompressionSessionInvalidate(session_);
      CFRelease(session_);
      session_ = NULL;
    }
    if (fmt_) {
      CFRelease(fmt_);
      fmt_ = NULL;
    }
  }

  bool ensure_session(const uint8_t *seq_obu, size_t seq_len,
                      const SeqInfo &si) {
    if (session_ && seq_obu_.size() == seq_len &&
        seq_obu_.compare(0, seq_len, (const char *)seq_obu, seq_len) == 0) {
      return true; // sequence unchanged
    }
    if (si.max_frame_width <= 0 || si.max_frame_height <= 0)
      return false;

    destroy_session();

    // av1C: 4-byte record header + sequence header OBU (as-is, with leb128)
    std::string av1c;
    av1c.push_back((char)0x81); // marker | version
    av1c.push_back((char)(si.seq_profile << 5 | si.seq_level_idx));
    av1c.push_back((char)(si.seq_tier << 7 | si.high_bitdepth << 6 |
                          si.twelve_bit << 5 | si.mono_chrome << 4 |
                          si.subsampling_x << 3 | si.subsampling_y << 2 |
                          si.chroma_sample_position));
    av1c.push_back((char)(si.initial_display_delay_present_flag
                              ? (1 << 4 | si.initial_display_delay_minus_1)
                              : 0));
    av1c.append((const char *)seq_obu, seq_len);

    CFDataRef av1c_data = CFDataCreate(
        kCFAllocatorDefault, (const UInt8 *)av1c.data(), (CFIndex)av1c.size());
    if (!av1c_data)
      return false;
    CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(atoms, CFSTR("av1C"), av1c_data);
    CFRelease(av1c_data);
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(
        spec, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
        atoms);
    CFRelease(atoms);
    CFDictionarySetValue(
        spec,
        kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
        kCFBooleanTrue);

    OSStatus st = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, kCMVideoCodecType_AV1, si.max_frame_width,
        si.max_frame_height, spec, &fmt_);
    if (st != noErr || !fmt_) {
      LOG_ERROR(std::string("CMVideoFormatDescriptionCreate failed: ") +
                std::to_string((int)st));
      CFRelease(spec);
      return false;
    }

#if defined(MAC_OS_VERSION_11_0) && !TARGET_OS_IPHONE && \
    (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_11_0) && \
    __has_builtin(__builtin_available)
    if (__builtin_available(macOS 11.0, *)) {
      VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1);
    }
#endif

    int32_t pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    int32_t w = si.max_frame_width;
    int32_t h = si.max_frame_height;
    CFNumberRef pf =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixfmt);
    CFNumberRef wn =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &w);
    CFNumberRef hn =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &h);
    CFMutableDictionaryRef io_props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, pf);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, io_props);
    CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, wn);
    CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, hn);
    CFRelease(pf);
    CFRelease(wn);
    CFRelease(hn);
    CFRelease(io_props);

    VTDecompressionOutputCallbackRecord cbr = {output_callback, this};
    st = VTDecompressionSessionCreate(kCFAllocatorDefault, fmt_, spec, attrs,
                                      &cbr, &session_);
    CFRelease(spec);
    CFRelease(attrs);
    if (st != noErr || !session_) {
      LOG_ERROR(std::string("VTDecompressionSessionCreate failed: ") +
                std::to_string((int)st));
      destroy_session();
      return false;
    }

    seq_obu_.assign((const char *)seq_obu, seq_len);
    width_ = si.max_frame_width;
    height_ = si.max_frame_height;
    LOG_INFO("AV1 VideoToolbox decoder created, " + std::to_string(width_) +
             "x" + std::to_string(height_));
    return true;
  }

  int decode(const uint8_t *data, int length, const void *obj) {
    if (!data || length <= 0)
      return -1;
    std::vector<Obu> obus = split_obus(data, (size_t)length);
    if (obus.empty())
      return -1;

    std::string sample;
    bool has_frame = false;
    for (size_t i = 0; i < obus.size(); i++) {
      const Obu &o = obus[i];
      if (o.type == OBU_TEMPORAL_DELIMITER)
        continue;
      if (o.type == OBU_SEQUENCE_HEADER) {
        SeqInfo si;
        if (!parse_sequence_header(o.payload, o.payload_len, si)) {
          LOG_ERROR("failed to parse AV1 sequence header");
          return -1;
        }
        if (!ensure_session(o.raw, o.raw_len, si))
          return -1;
      }
      if (o.type == OBU_FRAME)
        has_frame = true;
      sample.append((const char *)o.raw, o.raw_len);
    }
    if (!session_ || !has_frame || sample.empty())
      return -1;

    CMBlockBufferRef bb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, (void *)sample.data(), sample.size(),
        kCFAllocatorNull, NULL, 0, sample.size(), 0, &bb);
    if (st != noErr || !bb) {
      LOG_ERROR(std::string("CMBlockBufferCreateWithMemoryBlock failed: ") +
                std::to_string((int)st));
      return -1;
    }
    CMSampleTimingInfo timing = {CMTimeMake(1, 1000), CMTimeMake(0, 1000),
                                 CMTimeMake(0, 1000)};
    size_t sample_size = sample.size();
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, fmt_,
                              1, 1, &timing, 1, &sample_size, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) {
      LOG_ERROR(std::string("CMSampleBufferCreate failed: ") +
                std::to_string((int)st));
      return -1;
    }

    cur_obj_ = obj;
    cur_key_ = 1; // a new sequence always starts with a key frame
    frames_out_ = 0;
    cb_status_ = 0;
    st = VTDecompressionSessionDecodeFrame(session_, sb, 0, NULL, NULL);
    CFRelease(sb);
    if (st != noErr) {
      LOG_ERROR(std::string("VTDecompressionSessionDecodeFrame failed: ") +
                std::to_string((int)st));
      return -1;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session_);
    cur_obj_ = NULL;
    if (frames_out_ == 0) {
      LOG_ERROR(std::string("no frame decoded, cb status: ") +
                std::to_string((int)cb_status_));
      return -1;
    }
    return 0;
  }

  static void output_callback(void *refcon, void *source_frame,
                              OSStatus status, VTDecodeInfoFlags flags,
                              CVImageBufferRef image, CMTime pts,
                              CMTime duration) {
    VTAv1Decoder *self = (VTAv1Decoder *)refcon;
    if (status != noErr) {
      self->cb_status_ = status;
      return;
    }
    if (!image || !self->cur_obj_)
      return;
    self->on_frame(image);
  }

  void on_frame(CVImageBufferRef image) {
    OSType pf = CVPixelBufferGetPixelFormatType(image);
    int pixfmt;
    int planes;
    if (pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
      pixfmt = nv12_pixfmt_;
      planes = 2;
    } else if (pf == kCVPixelFormatType_420YpCbCr8Planar ||
               pf == kCVPixelFormatType_420YpCbCr8PlanarFullRange) {
      pixfmt = yuv420p_pixfmt_;
      planes = 3;
    } else {
      LOG_ERROR(std::string("unsupported output pixel format: ") +
                std::to_string((int)pf));
      cb_status_ = -1;
      return;
    }
    if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
      cb_status_ = -1;
      return;
    }
    int w = (int)CVPixelBufferGetWidth(image);
    int h = (int)CVPixelBufferGetHeight(image);
    int linesize[VT_AV1_NUM_DATA_POINTERS] = {0};
    uint8_t *plane_data[VT_AV1_NUM_DATA_POINTERS] = {NULL};
    bool ok = true;
    for (int i = 0; i < planes; i++) {
      plane_data[i] = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(image, i);
      linesize[i] = (int)CVPixelBufferGetBytesPerRowOfPlane(image, i);
      if (!plane_data[i] || linesize[i] <= 0)
        ok = false;
    }
    if (ok) {
      callback_(cur_obj_, w, h, pixfmt, linesize, plane_data, cur_key_);
      cur_key_ = 0;
      frames_out_++;
    } else {
      cb_status_ = -1;
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  }
};

} // namespace

void *vt_av1_decoder_create(VTAv1DecodeCallback callback, int nv12_pixfmt,
                            int yuv420p_pixfmt) {
  if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
    LOG_ERROR("AV1 hardware decode is not supported");
    return NULL;
  }
  return new VTAv1Decoder(callback, nv12_pixfmt, yuv420p_pixfmt);
}

int vt_av1_decoder_decode(void *decoder, const uint8_t *data, int length,
                          const void *obj) {
  if (!decoder)
    return -1;
  return ((VTAv1Decoder *)decoder)->decode(data, length, obj);
}

void vt_av1_decoder_destroy(void *decoder) {
  if (decoder)
    delete (VTAv1Decoder *)decoder;
}
