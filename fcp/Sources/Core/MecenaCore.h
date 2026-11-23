// SPDX-License-Identifier: GPL-3.0-or-later
// C interface of vendor/fxplug (Rust): the Gyroflow plugin base of the Resolve effect, for the FxPlug.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct MMStab MMStab;

MMStab *mm_stab_new(void);
void mm_stab_free(MMStab *s);
int mm_stab_set_file(MMStab *s, const char *path);
int mm_stab_set(MMStab *s, const char *name, double value);
double mm_stab_get(const MMStab *s, const char *name);
size_t mm_stab_text(const MMStab *s, const char *name, char *buf, size_t len);
void mm_stab_clip_info(const MMStab *s, double *fps, int64_t *frames);
int mm_stab_render(MMStab *s, int64_t frame, double master, void *input, size_t in_stride, void *output, size_t out_stride,
                   void *queue, size_t width, size_t height, int half, int textures);
int mm_mode_values(int mode, double *smoothness, double *horizon);
