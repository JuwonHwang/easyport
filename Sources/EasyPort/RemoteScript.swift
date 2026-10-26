import Foundation

/// 원격 서버에서 `sh -s`로 실행하는 스크립트. 사용자의 로그인 셸과 무관하게 POSIX sh로 실행한다.
enum RemoteScript {
    static let procMarker = "__EASYPORT_PROC__"
    static let httpMarker = "__EASYPORT_HTTP__"

    /// 출력 구성:
    /// 1. ss 출력
    /// 2. procMarker, 홈 디렉터리 한 줄, 포트를 연 프로세스와 그 조상마다
    ///    "pid<TAB>ppid<TAB>실행 초<TAB>comm<TAB>Claude 여부(1/0)<TAB>작업 디렉터리<TAB>명령줄".
    ///    Claude 여부는 환경 변수 CLAUDECODE=1 유무다. Claude Code의 Bash 도구가 실행한 프로세스와 그 자식에 있다.
    /// 3. httpMarker, 포트마다 "port<TAB>HTTP 상태<TAB>html 여부(1/0)<TAB>페이지 제목".
    ///    curl이 없으면 이 구역은 비어 있다. 포트마다 병렬로 1초 제한을 두고 요청한다.
    static let scan = #"""
    out=$( (ss -ltnpH || ss -ltnp | tail -n +2) 2>/dev/null )
    printf '%s\n' "$out"
    echo \#(procMarker)
    echo "$HOME"
    seen=" "
    for p in $(printf '%s\n' "$out" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un); do
      c=$p
      while [ -n "$c" ] && [ "$c" -gt 1 ]; do
        case "$seen" in *" $c "*) break ;; esac
        seen="$seen$c "
        pp=$(ps -o ppid= -p "$c" 2>/dev/null | tr -d ' ')
        cl=0
        tr '\0' '\n' < "/proc/$c/environ" 2>/dev/null | grep -qx 'CLAUDECODE=1' && cl=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "${pp:-0}" \
          "$(ps -o etimes= -p "$c" 2>/dev/null | tr -d ' ')" "$(cat "/proc/$c/comm" 2>/dev/null)" "$cl" \
          "$(readlink "/proc/$c/cwd" 2>/dev/null)" "$(tr '\0' ' ' < "/proc/$c/cmdline" 2>/dev/null)"
        c=$pp
      done
    done
    echo \#(httpMarker)
    if command -v curl >/dev/null 2>&1; then
      tmp=$(mktemp -d)
      done_ports=" "
      for la in $(printf '%s\n' "$out" | awk '{print $4}'); do
        port=${la##*:}
        case "$port" in 22|53) continue ;; esac
        case "$done_ports" in *" $port "*) continue ;; esac
        done_ports="$done_ports$port "
        addr=$(printf '%s' "${la%:*}" | tr -d '[]' | sed 's/%.*//')
        case "$addr" in 0.0.0.0|\*|::|127.*|::1) url="http://127.0.0.1:$port/" ;;
          *:*) url="http://[$addr]:$port/" ;;
          *) url="http://$addr:$port/" ;; esac
        (
          body=$(curl -s -m 1 -D "$tmp/$port" "$url" 2>/dev/null | head -c 16000 | tr '\r\n\t' '   ')
          code=$(head -1 "$tmp/$port" 2>/dev/null | awk '{print $2}')
          html=0
          grep -qi '^content-type:.*text/html' "$tmp/$port" 2>/dev/null && html=1
          title=$(printf '%s' "$body" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<.*/\1/p' | head -1)
          [ -n "$code" ] && printf '%s\t%s\t%s\t%s\n' "$port" "$code" "$html" "$title"
        ) &
      done
      wait
      rm -rf "$tmp"
    fi
    """#

    /// 프로세스 이름이 조회 때와 같은지 확인한 뒤 신호를 보낸다. 3초 안에 종료되지 않으면 종료 코드 5를 반환한다.
    /// 종료 코드: 0 종료됨, 3 PID가 없거나 다른 프로세스로 바뀜, 4 신호 전송 실패, 5 아직 실행 중.
    static func terminate(pid: Int, name: String, force: Bool) -> String {
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
        p=\#(pid)
        [ "$(cat /proc/$p/comm 2>/dev/null)" = \#(quoted) ] || exit 3
        kill -\#(force ? "KILL" : "TERM") "$p" 2>/dev/null || exit 4
        i=0
        while [ $i -lt 30 ]; do
          kill -0 "$p" 2>/dev/null || exit 0
          sleep 0.1
          i=$((i + 1))
        done
        exit 5
        """#
    }
}
