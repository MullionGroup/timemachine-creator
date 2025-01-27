#include "io_streamfile.h"

// StreamFileReader

StreamFileReader::StreamFileReader(std::string filename) : f(filename.c_str(), std::ios::in | std::ios::binary), filename(filename) {
  if (!f.good()) throw_error("StreamFileReader: error opening %s for reading\n", filename.c_str());
}

void StreamFileReader::read(unsigned char *dest, size_t pos, size_t length) {
  f.seekg(pos, std::ios_base::beg);
  f.read((char*)dest, length);
  if (f.fail()) {
#ifdef _WIN32
      throw_error("Error reading %Id bytes from file %s at position %Id",
                  length, filename.c_str(), pos);
#else
      throw_error("Error reading %zd bytes from file %s at position %zd",
                  length, filename.c_str(), pos);
#endif
  }
}

size_t StreamFileReader::length() {
  f.seekg(0, std::ios::end);
  return f.tellg();
}

FileReader *StreamFileReader::open(std::string filename) {
  return new StreamFileReader(filename);
}

namespace {
  bool reg1 = FileReader::register_opener(StreamFileReader::open);
}


// StreamFileWriter

StreamFileWriter::StreamFileWriter(std::string filename) : f(filename.c_str(), std::ios::out | std::ios::binary | std::ios::trunc), filename(filename) {
  if (!f.good()) throw_error("StreamFileWriter: error opening %s for writing\n", filename.c_str());
}

void StreamFileWriter::write(const unsigned char *src, size_t length) {
  f.write((char*)src, length);
  if (f.fail()) {
#ifdef _WIN32
      throw_error("Error writing %Id bytes to file %s", length, filename.c_str());
#else
      throw_error("Error writing %zd bytes to file %s", length, filename.c_str());
#endif
  }
}

FileWriter *StreamFileWriter::open(std::string filename) {
  return new StreamFileWriter(filename);
}

namespace {
  bool reg2 = FileWriter::register_opener(StreamFileWriter::open);
}
