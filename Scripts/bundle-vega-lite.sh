#!/bin/sh
# Reproduce the unmodified official browser bundles, with pinned npm integrity.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$repo_root/Sources/PicoMarkdownView/Resources/VegaLite" <<'PY'
import base64, hashlib, io, json, pathlib, sys, tarfile, urllib.request
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
pins = [
    ('vega', '6.2.0', 'build/vega.min.js', 'vega-6.2.0.min.js', 'sha512-BIwalIcEGysJdQDjeVUmMWB3e50jPDNAMfLJscjEvpunU9bSt7X1OYnQxkg3uBwuRRI4nWfFZO9uIW910nLeGw=='),
    ('vega-lite', '6.5.0', 'build/vega-lite.min.js', 'vega-lite-6.5.0.min.js', 'sha512-fMXF6s0MrIg0UTWnLIfeFtgSLzVhyzSKobzGrh5rhS+mL6FOYFG3m7ouJ4U23gj65EK+gl9FIIT5w7wLNaAzkA=='),
    ('vega-interpreter', '1.2.1', 'build/vega-interpreter.js', 'vega-interpreter-1.2.1.js', 'sha512-EMHLGxJ+SWfh1K/fHDRlHEZtLA/2ZNAXItYb5e8CxuAIm/Ha/3DHX/8VlvbTGIciUpuwmcKx4tVhJWlKreQ/Yw==')
]
provenance = []
for name, version, member, filename, integrity in pins:
    url = f'https://registry.npmjs.org/{name}/-/{name}-{version}.tgz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    actual = 'sha512-' + base64.b64encode(hashlib.sha512(archive).digest()).decode()
    if actual != integrity:
        raise SystemExit(f'Integrity mismatch: {name}@{version}')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
        data = package.extractfile('package/' + member).read()
        (out / filename).write_bytes(data)
        if name != 'vega-interpreter':
            (out / (name + '-LICENSE.txt')).write_bytes(package.extractfile('package/LICENSE').read())
    provenance.append(dict(package=name, version=version, archive=url, integrity=integrity,
                           file=filename, sha256=hashlib.sha256(data).hexdigest()))
# Interpreter 1.2.1 omits a LICENSE file from its npm tarball; its package
# metadata declares BSD-3-Clause and its upstream monorepo uses Vega's license.
(out / 'vega-interpreter-LICENSE.txt').write_bytes((out / 'vega-LICENSE.txt').read_bytes())
(out / 'vega-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Verified and copied three pinned official Vega browser bundles.')
PY
