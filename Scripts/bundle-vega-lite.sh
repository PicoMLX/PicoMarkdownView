#!/bin/sh
# Reproduce the official browser bundles, with pinned npm integrity. Vega and
# Vega-Lite are copied unmodified. vega-interpreter 2.x publishes only an ES
# module build, so its two module statements are rebound to the vega global.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$repo_root/Sources/PicoMarkdownView/Resources/VegaLite" <<'PY'
import base64, hashlib, io, json, pathlib, re, sys, tarfile, urllib.request
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
pins = [
    ('vega', '6.4.0', 'build/vega.min.js', 'vega-6.4.0.min.js', 'sha512-rHXCq2LpEWCLMjXBEj7hocY9G0/i5TGYRayGGSj06VTF4+l2IG2Z7oeZKCjWbUh/7hTE/mVhbaOPB72wCElh6g=='),
    ('vega-lite', '6.5.0', 'build/vega-lite.min.js', 'vega-lite-6.5.0.min.js', 'sha512-fMXF6s0MrIg0UTWnLIfeFtgSLzVhyzSKobzGrh5rhS+mL6FOYFG3m7ouJ4U23gj65EK+gl9FIIT5w7wLNaAzkA=='),
    ('vega-interpreter', '2.3.2', 'build/vega-interpreter.js', 'vega-interpreter-2.3.2.js', 'sha512-JDAoi3taFcCDLujZG84TNNUXdkAZ5WsSHssx8lWVYaxb9Slsjk7v7PtRIYXpSlUwLaKGRBqoJ9KDs36Z0eMEIw==')
]

def classic_script(module):
    # The bundled vega global re-exports vega-util, as the 1.x UMD build
    # assumed. Any other module statement means the build changed shape.
    source = module.decode('utf-8')
    imports = re.findall(r'^import .*$', source, re.M)
    exports = re.findall(r'^export .*$', source, re.M)
    names = re.fullmatch(r"import \{ ([\w, ]+) \} from 'vega-util';", imports[0]) if len(imports) == 1 else None
    local = re.fullmatch(r'export \{ (\w+) as expressionInterpreter \};', exports[0]) if len(exports) == 1 else None
    if not names or not local:
        raise SystemExit('Unexpected vega-interpreter module statements')
    source = source.replace(imports[0], 'const { ' + names.group(1) + ' } = vega;')
    source = source.replace(exports[0], 'vega.expressionInterpreter = ' + local.group(1) + ';')
    source = re.sub(r'^//# sourceMappingURL=.*\n?', '', source, flags=re.M)
    return ("(function () {\n'use strict';\n" + source.rstrip('\n') + '\n})();\n').encode('utf-8')

provenance = []
for name, version, member, filename, integrity in pins:
    url = f'https://registry.npmjs.org/{name}/-/{name}-{version}.tgz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    actual = 'sha512-' + base64.b64encode(hashlib.sha512(archive).digest()).decode()
    if actual != integrity:
        raise SystemExit(f'Integrity mismatch: {name}@{version}')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
        official = package.extractfile('package/' + member).read()
        (out / (name + '-LICENSE.txt')).write_bytes(package.extractfile('package/LICENSE').read())
    entry = dict(package=name, version=version, archive=url, integrity=integrity, file=filename)
    data = official
    if name == 'vega-interpreter':
        data = classic_script(official)
        entry.update(module=member, moduleSHA256=hashlib.sha256(official).hexdigest())
    (out / filename).write_bytes(data)
    entry['sha256'] = hashlib.sha256(data).hexdigest()
    provenance.append(entry)
(out / 'vega-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Verified and copied three pinned official Vega browser builds.')
PY
