"""Prépare l'envoi sur TestFlight (workflow ios-release.yml).

- Écrit la clé d'API dans KEY_PATH, au format PEM, même si elle a été collée sur une
  seule ligne ou sans ses lignes BEGIN et END.
- Si BUNDLE_ID manque, le retrouve dans App Store Connect : l'app du compte, ou celle
  dont le nom contient « FLUXA » s'il y en a plusieurs.
- Si TEAM_ID manque, prend le préfixe de l'identifiant de l'app (seedId), qui est
  l'identifiant de l'équipe.

Les valeurs trouvées sont ajoutées à GITHUB_ENV pour les étapes suivantes.
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


def get(path: str, bearer: str) -> list:
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["data"]
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        if error.code == 401:
            fail(
                "App Store Connect refuse la clé (401). Vérifiez ASC_KEY_ID, ASC_ISSUER_ID et ASC_KEY : "
                "les trois doivent venir de la même clé, qui ne doit pas être révoquée."
            )
        if error.code == 403:
            fail(f"La clé n'a pas les droits nécessaires (403). Donnez-lui le rôle Admin. {detail}")
        fail(f"App Store Connect a répondu {error.code} : {detail}")
        raise


def find_bundle_id(bearer: str) -> str:
    apps = get("/v1/apps?fields[apps]=name,bundleId&limit=200", bearer)
    if not apps:
        fail(
            "Aucune app dans App Store Connect. Créez-la (Apps → + → Nouvelle app) avec l'identifiant "
            "enregistré sur developer.apple.com, puis relancez."
        )
    if len(apps) > 1:
        named = [app for app in apps if "fluxa" in app["attributes"]["name"].lower()]
        if len(named) != 1:
            names = ", ".join(f"{app['attributes']['name']} ({app['attributes']['bundleId']})" for app in apps)
            fail(f"Plusieurs apps dans App Store Connect : {names}. Réglez la variable IOS_BUNDLE_ID.")
        apps = named
    return apps[0]["attributes"]["bundleId"]


def find_team_id(bundle_id: str, bearer: str) -> str:
    query = urllib.parse.urlencode({"filter[identifier]": bundle_id, "fields[bundleIds]": "identifier,seedId"})
    matches = [item for item in get(f"/v1/bundleIds?{query}", bearer) if item["attributes"]["identifier"] == bundle_id]
    if not matches:
        fail(
            f"L'identifiant {bundle_id} n'est pas enregistré sur developer.apple.com "
            "(Certificates, Identifiers & Profiles → Identifiers)."
        )
    return matches[0]["attributes"]["seedId"]


def main() -> None:
    pem = write_key()
    bundle_id = os.environ.get("BUNDLE_ID", "").strip()
    team_id = os.environ.get("TEAM_ID", "").strip()
    bearer = token(pem)
    if not bundle_id:
        bundle_id = find_bundle_id(bearer)
    if not team_id:
        team_id = find_team_id(bundle_id, bearer)
    with open(os.environ["GITHUB_ENV"], "a") as env:
        env.write(f"BUNDLE_ID={bundle_id}\nTEAM_ID={team_id}\n")
    print(f"::notice::App {bundle_id}, équipe {team_id}.")


if __name__ == "__main__":
    main()
