#!/bin/sh
# stand-in-curl.sh: a curl for tests/test_manage_models.sh, which
# answers like Hugging Face's API and serves small local files (see that
# test). F names the directory of files it serves, and LOG the file it
# logs each download to.
: "${F:?}" "${LOG:?}"
out="" headers="" path="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) headers="$2"; shift ;;
    --data-urlencode) path="${2#paths=}"; shift ;;
    -C | -d) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in
  */paths-info/*)
    f="$F/$(basename "$path")"
    if [ -f "$f" ]; then
      printf '[{"lfs": {"oid": "%s"}, "size": %s, "lastCommit": {"date": "2020-01-01T00:00:00.000Z"}}]\n' \
        "$(sha256sum "$f" | cut -d ' ' -f 1)" "$(wc -c < "$f")"
    else
      echo '[]'
    fi
    ;;
  */api/models/o/vis\?*)
    echo '{"gated": false, "cardData": {"license": "apache-2.0"}, "gguf": {"context_length": 8192}, "siblings": [{"rfilename": "README.md"}, {"rfilename": "mmproj-BF16.gguf"}, {"rfilename": "x.gguf"}, {"rfilename": "mmproj-F16.gguf"}, {"rfilename": "y.gguf"}]}'
    ;;
  */api/models/*)
    echo '{"gated": false, "cardData": {"license": "apache-2.0"}, "gguf": {"context_length": 8192}}'
    ;;
  */resolve/*)
    echo "$url" >> "$LOG"
    f="$F/$(basename "$url")"
    [ -f "$f.served" ] && f="$f.served"
    [ -f "$f" ] || exit 22
    printf 'HTTP/2 200\r\nx-repo-commit: %s\r\n' 0123456789abcdef0123456789abcdef01234567 > "$headers"
    cat "$f" > "$out"
    ;;
  *) exit 22 ;;
esac
