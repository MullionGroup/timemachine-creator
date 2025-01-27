#ifndef TILESTACK_H
#define TILESTACK_H

#include <assert.h>

#include "io.h"
#include "marshal.h"
#include "mathutils.h"

typedef unsigned char u8;
typedef unsigned short u16;

template <typename T> struct RGBA {
  T r, g, b, a;
  RGBA(T r, T g, T b, T a) : r(r), g(g), b(b), a(a) {}
  RGBA(){}
};

template <typename T> struct RGB { T r, g, b; };

struct PixelInfo {
  unsigned int bands_per_pixel;
  unsigned int bits_per_band;
  unsigned int pixel_format; // 0=unsigned integer, 1=floating point,
  enum { PIXEL_FORMAT_INTEGER = 0,
         PIXEL_FORMAT_FLOATING_POINT = 1 };
  unsigned int bytes_per_pixel() const { return bands_per_pixel * bits_per_band / 8; }

  double get_pixel_band(const unsigned char *pixel, unsigned band) const {
    switch ((bits_per_band << 1) | pixel_format) {
    case ((8 << 1) | 0):
      return ((unsigned char *)pixel)[band];
    case ((16 << 1) | 0):
      return ((unsigned short *)pixel)[band];
    case ((32 << 1) | 0):
      return ((unsigned int *)pixel)[band];
    case ((32 << 1) | 1):
      return ((float *)pixel)[band];
    case ((64 << 1) | 1):
      return ((double *)pixel)[band];
    default:
      throw_error("Can't read pixel type %d:%d", bits_per_band, pixel_format);
    }
  }

  unsigned char *get_pixel_band_ptr(const unsigned char *pixel, unsigned band) const {
    switch ((bits_per_band << 1) | pixel_format) {
    case ((8 << 1) | 0):
      return &((unsigned char *)pixel)[band];
    case ((16 << 1) | 0):
      return (unsigned char*)&((unsigned short *)pixel)[band];
    case ((32 << 1) | 0):
      return (unsigned char*)&((unsigned int *)pixel)[band];
    case ((32 << 1) | 1):
      return (unsigned char*)&((float *)pixel)[band];
    case ((64 << 1) | 1):
      return (unsigned char*)&((double *)pixel)[band];
    default:
      throw_error("Can't read pixel type %d:%d", bits_per_band, pixel_format);
    }
  }

  void set_pixel_band(unsigned char *pixel, unsigned band, double val) const {
    switch ((bits_per_band << 1) | pixel_format) {
    case ((8 << 1) | 0):
      ((unsigned char *)pixel)[band] = (unsigned char)iround(limit(val, (double)0x00, (double)0xff));
      break;
    case ((16 << 1) | 0):
      ((unsigned short *)pixel)[band] = (unsigned short)iround(limit(val, (double)0x0000, (double)0xffff));
      break;
    case ((32 << 1) | 0):
      ((unsigned int *)pixel)[band] = (unsigned int)iround(limit(val, (double)0x00000000, (double)0xffffffff));
      break;
    case ((32 << 1) | 1):
      ((float *)pixel)[band] = (float)val;
      break;
    case ((64 << 1) | 1):
      ((double *)pixel)[band] = val;
      break;
    default:
      throw_error("Can't write pixel type %d:%d", bits_per_band, pixel_format);
      break;
    }
  }

  std::string info() {
    return string_printf("%d bands of %d-bit %s",
                         bands_per_pixel, bits_per_band, pixel_format == PIXEL_FORMAT_INTEGER ? "integer" : "float");
  }
};

struct TilestackInfo : public PixelInfo {
  unsigned int nframes;
  unsigned int tile_width;
  unsigned int tile_height;
  unsigned int compression_format;
  enum CompressionFormat {
    NO_COMPRESSION = 0,
    ZLIB_COMPRESSION = 1
  };
  unsigned int bytes_per_frame() const { return bytes_per_pixel() * tile_width * tile_height; }
  std::string info() {
    return string_printf("%d frames of %d x %d pixels, each with %s", nframes, tile_width, tile_height,
                         PixelInfo::info().c_str());
  }
};

class Tilestack : public TilestackInfo {
public:
  struct TOCEntry {
    double timestamp;
    unsigned long long address, length;
  };
  mutable std::vector<TOCEntry> toc;
  mutable std::vector<unsigned char*> pixels;

public:
  double frame_timestamp(unsigned frame) {
    assert(frame < nframes);
    return toc[frame].timestamp;
  }
  unsigned char *frame_pixels(unsigned frame) const {
    assert(frame < nframes);
    if (!pixels[frame]) instantiate_pixels(frame);
    return pixels[frame];
  }
  void set_nframes(unsigned nframes) {
    this->nframes = nframes;
    toc.resize(nframes);
    pixels.resize(nframes);
  }
  unsigned char *frame_pixel(unsigned frame, unsigned x, unsigned y) const {
    return frame_pixels(frame) + bytes_per_pixel() * (x + y * tile_width);
  }
  void write(Writer *w) const;
  virtual ~Tilestack() {}
protected:
  virtual void instantiate_pixels(unsigned frame) const = 0;
  
};

/*
Options:

File-at-once:
 Read file into memory
 Parse header
 Decompress, or point to, frames only when requested, e.g. frameptr(frame) returns uncompressed

 Adv: large read (e.g. 250MB)
 Disadv: large read: higher latency, wasted effort when reading only a few frames, e.g. tour

Frames-on-demand:
 Read header into memory
 Parse header
 Read, and optionally decompress, a frame only when requested

 Adv: lower latency, no wasted effort
 Disadv: small read (e.g. 400K for uncompressed, 20K for JPEG-compressed)
 Consider reading multiple frames at once
*/

// TODO: support compressed formats by splitting all_pixels into multiple frames
class ResidentTilestack : public Tilestack {
  std::vector<unsigned char> all_pixels;
public:
  ResidentTilestack(const TilestackInfo &ti);
  virtual void instantiate_pixels(unsigned frame) const;
};

#endif
