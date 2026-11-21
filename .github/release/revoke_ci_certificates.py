"""Révoque les certificats de développement créés par la CI (workflow ios-release.yml).

Chaque envoi part d'une machine neuve, sans la clé privée du certificat précédent : la
signature automatique en crée un nouveau à chaque fois, jusqu'à la limite d'Apple, et
l'envoi échoue alors. Avant de signer, ce script révoque les certificats de
développement nommés « Created via API », ceux que crée la signature automatique avec
une clé d'API. Les certificats créés par Xcode sur un Mac (nommés d'après ce Mac) et
les certificats de distribution ne sont pas touchés. Un build déjà envoyé sur
TestFlight reste installable : il est signé pour la distribution.

Le dépôt est public, ses journaux aussi : seul le nombre de certificats est écrit.
"""

import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "ios", "Config"))

import appstoreconnect as asc  # noqa: E402

DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}
CREATED_BY_CI = "Created via API"


def to_revoke(certificates: list[dict]) -> list[str]:
    """Les identifiants des certificats de développement créés par la CI."""
    return [
        item["id"]
        for item in certificates
        if item["attributes"].get("certificateType") in DEVELOPMENT_TYPES
        and item["attributes"].get("displayName") == CREATED_BY_CI
    ]


def revoke(certificate_id: str, bearer: str) -> bool:
    request = urllib.request.Request(
        f"{asc.API}/v1/certificates/{certificate_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {bearer}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30):
            return True
    except urllib.error.HTTPError as error:
        print(f"::warning::Un certificat n'a pas pu être révoqué ({error.code}).")
        return False


def main() -> None:
    with open(os.environ["KEY_PATH"]) as file:
        bearer = asc.token(file.read())
    query = urllib.parse.urlencode(
        {
            "filter[certificateType]": ",".join(sorted(DEVELOPMENT_TYPES)),
            "fields[certificates]": "certificateType,displayName",
            "limit": 200,
        }
    )
    ids = to_revoke(asc.call(f"/v1/certificates?{query}", bearer))
    revoked = sum(revoke(certificate_id, bearer) for certificate_id in ids)
    print(f"::notice::{revoked} certificat(s) de développement créé(s) par la CI révoqué(s) sur {len(ids)}.")


if __name__ == "__main__":
    main()
