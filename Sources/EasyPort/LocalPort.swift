import Foundation

enum LocalPort {
    /// 127.0.0.1과 ::1 모두에서 bind할 수 있으면 비어 있는 포트로 본다.
    static func isFree(_ port: Int) -> Bool {
        canBind(port, ipv6: false) && canBind(port, ipv6: true)
    }

    /// 1024 미만 포트는 권한이 필요하므로 10000을 더한 번호부터 찾는다.
    static func firstFree(from start: Int, excluding used: Set<Int>) -> Int {
        var port = start < 1024 ? start + 10000 : start
        while port < 65535 {
            if !used.contains(port) && isFree(port) { return port }
            port += 1
        }
        return start
    }

    /// 127.0.0.1:port에 TCP 연결이 되는지 확인한다.
    static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func canBind(_ port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            // IPv6를 쓸 수 없는 환경이면 IPv4 결과만 따른다.
            return result == 0 || errno == EADDRNOTAVAIL
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return result == 0
        }
    }
}
