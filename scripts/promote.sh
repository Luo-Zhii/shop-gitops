#!/usr/bin/env bash
# Promote tag image giữa môi trường bằng PR: chép images.<svc> từ <from> sang <to>.
#   scripts/promote.sh dev staging            # mọi service
#   scripts/promote.sh staging prod-onprem order payment
# Sau đó: git switch -c promote/<to>-$(date +%Y%m%d) && git commit -am "chore(promote): ..." && gh pr create
set -euo pipefail
from="$1"; to="$2"; shift 2
python3 - "$from" "$to" "$@" <<'PY'
import re, sys
src, dst, only = sys.argv[1], sys.argv[2], set(sys.argv[3:])
pat = re.compile(r'^  ([a-z0-9-]+): \{tag: "([^"]*)", digest: "([^"]*)"\}$')
read = lambda e: open(f"environments/{e}/images.yaml").read().splitlines()
tags = {m[1]: (m[2], m[3]) for l in read(src) if (m := pat.match(l))}
out, changed = [], []
for l in read(dst):
    m = pat.match(l)
    if m and m[1] in tags and (not only or m[1] in only) and tags[m[1]] != (m[2], m[3]):
        t, d = tags[m[1]]
        l = f'  {m[1]}: {{tag: "{t}", digest: "{d}"}}'
        changed.append(f"{m[1]} {m[2]} -> {t}")
    out.append(l)
open(f"environments/{dst}/images.yaml", "w").write("\n".join(out) + "\n")
print("\n".join(changed) or "không có gì thay đổi")
PY
