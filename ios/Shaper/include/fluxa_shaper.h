// L'ABI C du module Rust fluxa-shaper (ios/Shaper/src/lib.rs).
//
// fluxa_shaper_try_apply tente d'appliquer un plafond de débit au partage de connexion
// par les mécanismes du noyau, et renvoie le rapport de chaque tentative en JSON (UTF-8),
// à rendre avec fluxa_shaper_free. Un plafond nul vaut « sans plafond ».

#ifndef FLUXA_SHAPER_H
#define FLUXA_SHAPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *fluxa_shaper_try_apply(uint64_t download_bps, uint64_t upload_bps);
void fluxa_shaper_free(char *report);
const char *fluxa_shaper_version(void);

#ifdef __cplusplus
}
#endif

#endif
