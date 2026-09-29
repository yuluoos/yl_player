/* Research-only C ABI smoke test against pinned libdovi 3.4.0.
 * No renderer, production integration, or quality assertion. */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct RpuOpaque RpuOpaque;
extern RpuOpaque *dovi_parse_unspec62_nalu(const unsigned char *, size_t);
extern const char *dovi_rpu_get_error(const RpuOpaque *);
extern void dovi_rpu_free(RpuOpaque *);
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    unsigned char data[65537];
    size_t count = fread(data, 1, sizeof(data), file);
    int failed = ferror(file);
    fclose(file);
    if (failed || count == 0 || count > 65536) return 2;
    RpuOpaque *invalid = dovi_parse_unspec62_nalu(NULL, 0);
    int rejected = invalid && dovi_rpu_get_error(invalid);
    dovi_rpu_free(invalid);
    RpuOpaque *rpu = dovi_parse_unspec62_nalu(data, count);
    int accepted = rpu && !dovi_rpu_get_error(rpu);
    dovi_rpu_free(rpu);
    if (!rejected || !accepted) return 1;
    puts("libdovi C ABI: invalid input rejected, one original RPU parsed and freed");
    return 0;
}
