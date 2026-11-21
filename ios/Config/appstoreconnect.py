"""Prépare l'envoi sur TestFlight (workflow ios-release.yml).

- Écrit la clé d'API dans KEY_PATH, au format PEM, même si elle a été collée sur une
  seule ligne ou sans ses lignes BEGIN et END.
- Enregistre l'identifiant de l'app (BUNDLE_ID) sur le compte développeur s'il ne l'est
  pas encore, et en tire l'identifiant de l'équipe (le préfixe seedId) si TEAM_ID manque.
- Enregistre l'identifiant de l'extension du relais (BUNDLE_ID.relay) et active les
  extensions réseau sur les deux identifiants ; enregistre celui des widgets
  (BUNDLE_ID.widgets) et active les groupes d'apps sur l'app et les widgets. Le groupe
  lui-même (group.BUNDLE_ID) est enregistré par la signature automatique de Xcode.
- Vérifie que l'app existe dans App Store Connect : une app ne peut pas y être créée par
  l'API, il faut le faire une fois à la main.

Le dépôt est public, ses journaux aussi : rien d'autre que l'identifiant de FLUXA n'est
écrit dans les messages.
"""

import json
import os
import re
import sys
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def write_key() -> str:
    raw = os.environ["ASC_PRIVATE_KEY"].replace("\\n", "\n")
    body = re.sub(r"-----(BEGIN|END)[A-Z ]*-----", "", raw)
    body = re.sub(r"\s+", "", body)
    if not body:
        fail("Le secret ASC_KEY est vide.")
    pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----\n"
    path = os.environ["KEY_PATH"]
    with open(path, "w") as file:
        file.write(pem)
    os.chmod(path, 0o600)
    return pem


def token(pem: str) -> str:
    now = int(time.time())
    try:
        return jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
            pem,
            algorithm="ES256",
            headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
        )
    except Exception as error:  # clé illisible
        fail(f"La clé d'API ne peut pas être lue ({error}). Vérifiez le contenu du secret ASC_KEY.")
        raise


def call(path: str, bearer: str, body: dict | None = None, tolerate: tuple[int, ...] = ()) -> list | dict | None:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        API + path,
        data=data,
        method="POST" if body is not None else "GET",
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["data"]
    except urllib.error.HTTPError as error:
        if error.code in tolerate:
            return None
        if error.code == 401:
            fail(
                "App Store Connect refuse la clé (401). Vérifiez ASC_KEY_ID, ASC_ISSUER_ID et ASC_KEY : "
                "les trois doivent venir de la même clé, qui ne doit pas être révoquée."
            )
        if error.code == 403:
            fail("La clé n'a pas les droits nécessaires (403). Donnez-lui le rôle Admin.")
        fail(f"App Store Connect a répondu {error.code} à {path.split('?')[0]}.")
        raise


def bundle_record(bundle_id: str, bearer: str, name: str = "FLUXA") -> dict:
    """L'identifiant sur le compte développeur, enregistré au besoin."""
    query = urllib.parse.urlencode({"filter[identifier]": bundle_id, "fields[bundleIds]": "identifier,seedId"})
    for item in call(f"/v1/bundleIds?{query}", bearer):
        if item["attributes"]["identifier"] == bundle_id:
            return item
    print(f"::notice::Enregistrement de l'identifiant {bundle_id} sur le compte développeur.")
    return call(
        "/v1/bundleIds",
        bearer,
        {"data": {"type": "bundleIds", "attributes": {"identifier": bundle_id, "name": name, "platform": "IOS"}}},
    )


def enable_network_extensions(record: dict, bearer: str) -> None:
    """Active les extensions réseau sur l'identifiant (le relais en arrière-plan)."""
    enable(record, "NETWORK_EXTENSIONS", bearer)


def enable(record: dict, capability: str, bearer: str) -> None:
    """Active une capacité sur l'identifiant. Une capacité déjà active fait répondre 409 :
    rien à faire."""
    call(
        "/v1/bundleIdCapabilities",
        bearer,
        {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": capability},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": record["id"]}}},
            }
        },
        tolerate=(409,),
    )


def check_app(bundle_id: str, bearer: str) -> None:
    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"})
    if not any(app["attributes"]["bundleId"] == bundle_id for app in call(f"/v1/apps?{query}", bearer)):
        fail(
            f"L'app n'existe pas encore dans App Store Connect. Créez-la une fois : Apps → + → Nouvelle app, "
            f"plateforme iOS, nom FLUXA, langue français, identifiant {bundle_id} (il est enregistré et "
            "figure dans la liste), SKU fluxa-ios. Puis relancez ce workflow."
        )


def main() -> None:
    pem = write_key()
    bundle_id = os.environ.get("BUNDLE_ID", "").strip()
    if not bundle_id:
        fail("L'identifiant de l'app (BUNDLE_ID) est vide.")
    bearer = token(pem)
    record = bundle_record(bundle_id, bearer)
    team_id = os.environ.get("TEAM_ID", "").strip() or record["attributes"]["seedId"]
    check_app(bundle_id, bearer)
    # L'extension du relais a son propre identifiant ; les deux portent les extensions réseau.
    relay = bundle_record(f"{bundle_id}.relay", bearer, name="FLUXA Relais")
    for item in (record, relay):
        enable_network_extensions(item, bearer)
    # Les widgets ont aussi leur identifiant ; l'app et eux partagent un groupe d'apps.
    widgets = bundle_record(f"{bundle_id}.widgets", bearer, name="FLUXA Widgets")
    for item in (record, widgets):
        enable(item, "APP_GROUPS", bearer)
    with open(os.environ["GITHUB_ENV"], "a") as env:
        env.write(f"BUNDLE_ID={bundle_id}\nTEAM_ID={team_id}\n")
    # L'identifiant de l'équipe est masqué dans le journal public.
    print(f"::add-mask::{team_id}")
    print(f"::notice::App {bundle_id} trouvée dans App Store Connect.")


if __name__ == "__main__":
    main()
