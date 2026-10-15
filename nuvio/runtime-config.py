"""Use only the public discovery document and an optional operator-owned TMDB key."""
import json
import os
import pathlib
import sys
import urllib.request

root = pathlib.Path(sys.argv[1]).resolve()
request = urllib.request.Request('https://api.nuvio.tv/.well-known/nuvio', headers={'Accept': 'application/json'})
with urllib.request.urlopen(request, timeout=30) as response:
    if response.geturl() != request.full_url:
        raise RuntimeError('Unexpected discovery redirect')
    raw = response.read(65537)
if len(raw) > 65536:
    raise RuntimeError('Discovery document too large')
document = json.loads(raw)
if document.get('service') != 'nuvio' or document.get('version') != 1:
    raise RuntimeError('Unexpected discovery document')
if document.get('backend_url', '').rstrip('/') != 'https://api.nuvio.tv':
    raise RuntimeError('Unexpected backend; no credentials will be forwarded')
key = document.get('publishable_key', '')
if not isinstance(key, str) or not key or any(c in key for c in '\n\r\\"'):
    raise RuntimeError('Invalid public client configuration')
tmdb = os.environ.get('TMDB_API_KEY', '').strip()
if any(c in tmdb for c in '\n\r\\"'):
    raise RuntimeError('Invalid TMDB configuration')
if os.environ.get('GITHUB_ACTIONS'):
    print('::add-mask::' + key)
    if tmdb:
        print('::add-mask::' + tmdb)
properties = 'NUVIO_SUPABASE_URL=https://api.nuvio.tv\nNUVIO_SUPABASE_ANON_KEY=' + key + '\n'
properties += 'TMDB_API_KEY=' + tmdb + '\n'
(root / 'local.properties').write_text(properties, encoding='utf-8')
print(json.dumps({'public_discovery': 'configured', 'tmdb_operator_key': bool(tmdb),
                  'note': 'TMDB enrichment requires an operator key or a key entered in app settings'}))
