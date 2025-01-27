#include <assert.h>

#include <stdexcept>
#include <vector>

#include "cpp_utils.h"
#include "marshal.h"

#include "ImageReader.h"

////// ImageReader

ImageReader *ImageReader::open(const std::string &filename) {
  std::string format = filename_suffix(filename);
  if (iequals(format, "jpg")) return new JpegReader(filename);
  if (iequals(format, "kro")) return new KroReader(filename);
  if (iequals(format, "png")) return new PngReader(filename);
  throw_error("Unrecognized image format from filename %s", filename.c_str());
}

////// JpegReader

JpegReader::JpegReader(const std::string &filename) : filename(filename) {
  in = fopen(filename.c_str(), "rb");
  if (!in) throw_error("Can't open %s for reading", filename.c_str());

  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_decompress(&cinfo);
  jpeg_stdio_src(&cinfo, in);
  jpeg_read_header(&cinfo, TRUE);
  jpeg_start_decompress(&cinfo);
  m_bands_per_pixel = cinfo.output_components;
  m_bits_per_band = 8;
  m_width = cinfo.output_width;
  m_height = cinfo.output_height;
}

void JpegReader::read_rows(unsigned char *pixels, unsigned int nrows) const {
  std::vector<unsigned char*> rowptrs(nrows);
  for (unsigned i = 0; i < nrows; i++) {
    rowptrs[i] = pixels + i * bytes_per_row();
  }
  unsigned nread = 0;
  while (nread < nrows) {
    nread += jpeg_read_scanlines(&cinfo, &rowptrs[nread], nrows - nread);
  }
}

void JpegReader::close() {
  if (in) {
    jpeg_abort_decompress(&cinfo); // abort rather than finish because we might not have read all lines
    jpeg_destroy_decompress(&cinfo);
    fclose(in);
    in = NULL;
  }
}

JpegReader::~JpegReader() {
  close();
}

////// KroReader

KroReader::KroReader(const std::string &filename) : filename(filename) {
  in = fopen(filename.c_str(), "rb");
  if (!in) throw_error("Can't open %s for reading", filename.c_str());

  unsigned char header[20];
  if (1 != fread(header, sizeof(header), 1, in)) {
    throw_error("Can't read header from %s", filename.c_str());
  }
  unsigned int magic = read_u32_be(&header[0]);
  if (magic != 0x4b52f401) {
    throw_error("Incorrect magic number for KRO file: 0x%x", magic);
  }
  m_width = read_u32_be(&header[4]);
  m_height = read_u32_be(&header[8]);
  m_bits_per_band = read_u32_be(&header[12]);
  m_bands_per_pixel = read_u32_be(&header[16]); 
}

void KroReader::read_rows(unsigned char *pixels, unsigned int nrows) const {
  if (1 != fread(pixels, bytes_per_row() * nrows, 1, in)) {
    throw_error("Can't read pixels from %s", filename.c_str());
  }
}

void KroReader::close() {
  if (in) {
    fclose(in);
    in = NULL;
  }
}

KroReader::~KroReader() {
  close();
}

////// PngReader

PngReader::PngReader(const std::string &filename) : filename(filename) {
  in = NULL;
  png_read = NULL;
  png_info = NULL;
  
  in = fopen(filename.c_str(), "rb");
  if (!in) throw_error("Can't open %s for reading", filename.c_str());

  unsigned char header[8];
  if (1 != fread(header, sizeof(header), 1, in)) {
    throw_error("Can't read header from %s", filename.c_str());
  }
  
  if (png_sig_cmp(header, 0, 8)) {
    throw_error("%s does not appear to be a PNG file", filename.c_str());
  }
  
  png_read = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  
  if (!png_read) {
    throw_error("PngReader: initialization failed");
  }
  
  png_info = png_create_info_struct(png_read);
  if (!png_info) {
    throw_error("PngReader: initialization failed");
  }
  
  png_init_io(png_read, in);
  png_set_sig_bytes(png_read, 8);
  
  png_read_info(png_read, png_info);
  
  m_width = png_get_image_width(png_read, png_info);
  m_height = png_get_image_height(png_read, png_info);
  switch (png_get_color_type(png_read, png_info)) {
  case PNG_COLOR_TYPE_GRAY: m_bands_per_pixel = 1; break;
  case PNG_COLOR_TYPE_GRAY_ALPHA: m_bands_per_pixel = 2; break;
  case PNG_COLOR_TYPE_RGB: m_bands_per_pixel = 3; break;
  case PNG_COLOR_TYPE_RGBA: m_bands_per_pixel = 4; break;
  default:
    throw_error("%s: unsupported PNG type %d", filename.c_str(), png_get_color_type(png_read, png_info));
  }
  m_bits_per_band = png_get_bit_depth(png_read, png_info);
  
  int number_of_passes = png_set_interlace_handling(png_read);
  if (number_of_passes != 1) {
    throw_error("PngReader: can't handle interlaced png %s", filename.c_str());
  }

  png_read_update_info(png_read, png_info);
}

void PngReader::read_rows(unsigned char *pixels, unsigned int nrows) const {
  std::vector<unsigned char*> rowptrs(nrows);
  for (unsigned i = 0; i < nrows; i++) {
    rowptrs[i] = pixels + i * bytes_per_row();
  }
  png_read_rows(png_read, &rowptrs[0], NULL, nrows);
}

void PngReader::close() {
  if (png_info || png_read) {
    png_destroy_read_struct(png_read ? &png_read : NULL,
                            png_info ? &png_info : NULL, 
                            NULL);
    png_info = NULL;
    png_read = NULL;
  }

  if (in) { 
    fclose(in); 
    in = NULL;
  }
}

PngReader::~PngReader() {
  close();
}
