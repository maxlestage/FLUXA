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

// Le relais de partage : un mandataire HTTP, HTTPS (CONNECT) et SOCKS5 sur l'iPhone, qui
// relaie et plafonne le trafic des appareils du partage de connexion réglés sur lui.
// Les plafonds sont en bits par seconde ; zéro vaut « sans plafond ». Les fonctions qui
// renvoient un int32_t rendent 0, ou un code d'erreur du système (errno).
int32_t fluxa_relay_start(uint16_t port, uint8_t allow_loopback);
void fluxa_relay_stop(void);
void fluxa_relay_set_limit(uint64_t download_bps, uint64_t upload_bps);
int32_t fluxa_relay_set_device_limit(const char *address, uint64_t download_bps, uint64_t upload_bps);
// L'état du relais en JSON (plafonds en octets par seconde), à rendre avec fluxa_shaper_free.
char *fluxa_relay_status(void);

#ifdef __cplusplus
}
#endif

#endif
