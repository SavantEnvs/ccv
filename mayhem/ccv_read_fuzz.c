#include <ccv.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The BMP, PNG, JPEG and CCVBINDM readers size the matrix from unvalidated header fields. Reject headers
// whose matrix would be malformed (unknown data type, no channels, non-positive or oversized dimensions)
// or larger than 4M elements, so inputs do not all end in the same huge allocation, int overflow or
// data-type table over-index.
#define MAX_ELEMENTS ((uint64_t)1 << 22)

static int oversized(int64_t rows, int64_t cols, int64_t channels)
{
	if (rows <= 0 || cols <= 0 || channels <= 0 || rows > (int64_t)MAX_ELEMENTS || cols > (int64_t)MAX_ELEMENTS)
		return 1;
	return (uint64_t)rows * (uint64_t)cols * (uint64_t)channels > MAX_ELEMENTS;
}

static int invalid_header(const uint8_t* buf, size_t len, int channels)
{
	int32_t type, rows, cols;
	if (len >= 8 && memcmp(buf, "CCVBINDM", 8) == 0)
	{
		if (len < 20) // the reader consumes a 12-byte header after the signature
			return 1;
		memcpy(&type, buf + 8, 4); // matrix type: low 12 bits channels, bits 12-19 the data type
		memcpy(&rows, buf + 12, 4);
		memcpy(&cols, buf + 16, 4);
		const uint32_t data_type = ((uint32_t)type >> 12) & 0xFF;
		if (data_type == 0 || (data_type & (data_type - 1)) != 0) // exactly one data-type bit
			return 1;
		return oversized(rows, cols, type & 0xFFF);
	}
	if (len >= 26 && buf[0] == 'B' && buf[1] == 'M')
	{
		memcpy(&cols, buf + 18, 4); // width
		memcpy(&rows, buf + 22, 4); // height
		return oversized(rows, cols, channels);
	}
	if (len >= 24 && memcmp(buf, "\x89PNG\r\n\x1a\n", 8) == 0)
	{
		const uint8_t* p = buf + 16; // IHDR width and height, big endian
		const uint32_t w = (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
		const uint32_t h = (uint32_t)p[4] << 24 | p[5] << 16 | p[6] << 8 | p[7];
		return oversized(h, w, channels);
	}
	if (len >= 4 && buf[0] == 0xFF && buf[1] == 0xD8)
	{
		size_t i = 2;
		while (i + 4 <= len)
		{
			const uint8_t marker = buf[i + 1];
			if (buf[i] != 0xFF || marker == 0xFF || marker == 0x00) // libjpeg resyncs on junk and fill bytes
			{
				i++;
				continue;
			}
			if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) // SOFn
			{
				if (i + 9 > len)
					return 0;
				const uint32_t h = (uint32_t)buf[i + 5] << 8 | buf[i + 6];
				const uint32_t w = (uint32_t)buf[i + 7] << 8 | buf[i + 8];
				return oversized(h, w, channels);
			}
			if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) // markers without a length
			{
				i += 2;
				continue;
			}
			i += 2 + ((size_t)buf[i + 2] << 8 | buf[i + 3]);
		}
	}
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	// ccv_read on a stream requires more than 8 bytes; the first byte picks the output colour mode.
	if (size <= 9)
		return -1;
	const int gray = data[0] & 1;
	if (invalid_header(data + 1, size - 1, gray ? 1 : 3))
		return -1;
	ccv_dense_matrix_t* image = 0;
	const int type = (gray ? CCV_IO_GRAY : CCV_IO_RGB_COLOR) | CCV_IO_ANY_STREAM;
	ccv_read(data + 1, &image, type, (int)(size - 1));
	if (image)
		ccv_matrix_free(image);
	return 0;
}
