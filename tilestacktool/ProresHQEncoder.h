#ifndef INCLUDE_PRORESHQ_ENCODER_H
#define INCLUDE_PRORESHQ_ENCODER_H

#include "VideoEncoder.h"
#include <string>
#include <stdlib.h>
#ifndef _WIN32
	#include <unistd.h>
#endif

#include "cpp_utils.h"

class ProresHQEncoder : public VideoEncoder {
  size_t total_written;
  std::string tmp_filename;
  std::string dest_filename;
  int width, height;
  double fps, compression;
  FILE *out;

public:
  ProresHQEncoder(std::string dest_filename, int width, int height, double fps, double compression);
  void write_pixels(unsigned char *pixels, size_t len);
  void close();

  static bool test();
  static std::string path_to_ffmpeg();
  static std::string ffmpeg_path_override;
  static std::string path_to_executable(std::string executable);
};

#endif