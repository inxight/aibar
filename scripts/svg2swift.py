#!/usr/bin/env python3
"""SVG path(d 속성)를 Swift 벡터 데이터로 바꾼다.

런타임 SVG 파서를 앱에 넣지 않으려고, 빌드 전에 한 번만 변환해 소스로 박아 넣는다.
지원 명령: M m L l H h V v C c S s Q q T t A a Z z
호(A/a)는 표준 방식으로 3차 베지어 여러 개로 근사한다.
"""
import math
import re
import sys

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
CMD = re.compile(r'([MmLlHhVvCcSsQqTtAaZz])')


def tokenize(d):
    """[(명령, [숫자...]), ...] 로 쪼갠다."""
    out = []
    parts = CMD.split(d)
    i = 1
    while i < len(parts):
        cmd = parts[i]
        args = [float(x) for x in NUM.findall(parts[i + 1])] if i + 1 < len(parts) else []
        out.append((cmd, args))
        i += 2
    return out


def arc_to_curves(x0, y0, rx, ry, phi_deg, large_arc, sweep, x1, y1):
    """SVG 호를 3차 베지어 목록으로. 반환: [(c1x,c1y,c2x,c2y,ex,ey), ...]"""
    if x0 == x1 and y0 == y1:
        return []
    if rx == 0 or ry == 0:
        return [(x0, y0, x1, y1, x1, y1)]

    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg % 360.0)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)

    # 1) 시작점을 타원 좌표계로
    dx2, dy2 = (x0 - x1) / 2.0, (y0 - y1) / 2.0
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2

    # 2) 반지름 보정
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale

    # 3) 중심 구하기
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, num / den)) if den != 0 else 0.0
    if large_arc == sweep:
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x0 + x1) / 2.0
    cy = sin_phi * cxp + cos_phi * cyp + (y0 + y1) / 2.0

    # 4) 각도
    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        if n == 0:
            return 0.0
        a = math.acos(max(-1.0, min(1.0, dot / n)))
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                   (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    # 5) 90도씩 쪼개 베지어로
    segments = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2))))
    delta = dtheta / segments
    t = (4.0 / 3.0) * math.tan(delta / 4.0)

    curves = []
    theta = theta1
    for _ in range(segments):
        cos1, sin1 = math.cos(theta), math.sin(theta)
        theta2 = theta + delta
        cos2, sin2 = math.cos(theta2), math.sin(theta2)

        def point(c, s):
            return (cos_phi * rx * c - sin_phi * ry * s + cx,
                    sin_phi * rx * c + cos_phi * ry * s + cy)

        def deriv(c, s):
            return (-cos_phi * rx * s - sin_phi * ry * c,
                    -sin_phi * rx * s + cos_phi * ry * c)

        px, py = point(cos1, sin1)
        ex, ey = point(cos2, sin2)
        d1x, d1y = deriv(cos1, sin1)
        d2x, d2y = deriv(cos2, sin2)
        curves.append((px + t * d1x, py + t * d1y,
                       ex - t * d2x, ey - t * d2y,
                       ex, ey))
        theta = theta2
    return curves


def convert(d):
    """SVG path → [('m'|'l'|'c'|'z', 좌표...)] 절대좌표."""
    out = []
    x = y = 0.0
    sx = sy = 0.0           # subpath 시작점
    prev_cmd = None
    prev_ctrl = None        # S/T 용 직전 제어점

    for cmd, args in tokenize(d):
        upper = cmd.upper()
        rel = cmd.islower()

        if upper == 'Z':
            out.append(('z',))
            x, y = sx, sy
            prev_ctrl = None
            prev_cmd = upper
            continue

        # 명령별 인자 개수
        step = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7}[upper]
        if not args:
            continue

        for i in range(0, len(args), step):
            chunk = args[i:i + step]
            if len(chunk) < step:
                break

            if upper == 'M':
                nx, ny = chunk
                if rel:
                    nx, ny = x + nx, y + ny
                # M 뒤에 좌표가 이어지면 그 뒤는 L 로 친다
                if i == 0:
                    out.append(('m', nx, ny))
                    sx, sy = nx, ny
                else:
                    out.append(('l', nx, ny))
                x, y = nx, ny
                prev_ctrl = None

            elif upper == 'L':
                nx, ny = chunk
                if rel:
                    nx, ny = x + nx, y + ny
                out.append(('l', nx, ny))
                x, y = nx, ny
                prev_ctrl = None

            elif upper == 'H':
                nx = chunk[0] + (x if rel else 0)
                out.append(('l', nx, y))
                x = nx
                prev_ctrl = None

            elif upper == 'V':
                ny = chunk[0] + (y if rel else 0)
                out.append(('l', x, ny))
                y = ny
                prev_ctrl = None

            elif upper == 'C':
                c1x, c1y, c2x, c2y, nx, ny = chunk
                if rel:
                    c1x, c1y = x + c1x, y + c1y
                    c2x, c2y = x + c2x, y + c2y
                    nx, ny = x + nx, y + ny
                out.append(('c', c1x, c1y, c2x, c2y, nx, ny))
                prev_ctrl = (c2x, c2y)
                x, y = nx, ny

            elif upper == 'S':
                c2x, c2y, nx, ny = chunk
                if rel:
                    c2x, c2y = x + c2x, y + c2y
                    nx, ny = x + nx, y + ny
                if prev_cmd in ('C', 'S') and prev_ctrl:
                    c1x, c1y = 2 * x - prev_ctrl[0], 2 * y - prev_ctrl[1]
                else:
                    c1x, c1y = x, y
                out.append(('c', c1x, c1y, c2x, c2y, nx, ny))
                prev_ctrl = (c2x, c2y)
                x, y = nx, ny

            elif upper == 'Q':
                qx, qy, nx, ny = chunk
                if rel:
                    qx, qy = x + qx, y + qy
                    nx, ny = x + nx, y + ny
                # 2차 → 3차
                c1x, c1y = x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y)
                c2x, c2y = nx + 2.0 / 3.0 * (qx - nx), ny + 2.0 / 3.0 * (qy - ny)
                out.append(('c', c1x, c1y, c2x, c2y, nx, ny))
                prev_ctrl = (qx, qy)
                x, y = nx, ny

            elif upper == 'T':
                nx, ny = chunk
                if rel:
                    nx, ny = x + nx, y + ny
                if prev_cmd in ('Q', 'T') and prev_ctrl:
                    qx, qy = 2 * x - prev_ctrl[0], 2 * y - prev_ctrl[1]
                else:
                    qx, qy = x, y
                c1x, c1y = x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y)
                c2x, c2y = nx + 2.0 / 3.0 * (qx - nx), ny + 2.0 / 3.0 * (qy - ny)
                out.append(('c', c1x, c1y, c2x, c2y, nx, ny))
                prev_ctrl = (qx, qy)
                x, y = nx, ny

            elif upper == 'A':
                rx, ry, rot, large, sweep, nx, ny = chunk
                if rel:
                    nx, ny = x + nx, y + ny
                for c in arc_to_curves(x, y, rx, ry, rot, int(large), int(sweep), nx, ny):
                    out.append(('c',) + c)
                x, y = nx, ny
                prev_ctrl = None

            prev_cmd = upper
    return out


def to_swift(name, elements, indent='        '):
    lines = []
    for e in elements:
        if e[0] == 'z':
            lines.append(f'{indent}.close,')
        elif e[0] == 'm':
            lines.append(f'{indent}.move({e[1]:.4f}, {e[2]:.4f}),')
        elif e[0] == 'l':
            lines.append(f'{indent}.line({e[1]:.4f}, {e[2]:.4f}),')
        elif e[0] == 'c':
            lines.append(
                f'{indent}.curve({e[1]:.4f}, {e[2]:.4f}, {e[3]:.4f}, {e[4]:.4f}, {e[5]:.4f}, {e[6]:.4f}),'
            )
    body = '\n'.join(lines)
    return f'    static let {name}: [BrandPathElement] = [\n{body}\n    ]'


def main():
    blocks = []
    for name, path in [('claude', sys.argv[1]), ('openai', sys.argv[2])]:
        d = re.search(r'd="([^"]+)"', open(path).read()).group(1)
        elements = convert(d)
        blocks.append(to_swift(name, elements))
        print(f'// {name}: {len(elements)} elements', file=sys.stderr)

    header = '''import CoreGraphics

/// SVG 로고를 미리 변환해 둔 벡터 데이터. 좌표계는 원본과 같은 24x24 이고 y 는 아래로 증가한다.
/// (원본 SVG: simple-icons, CC0)
enum BrandPathElement {
    case move(CGFloat, CGFloat)
    case line(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
}

enum BrandPaths {
    /// 원본 SVG 의 viewBox 한 변.
    static let viewBox: CGFloat = 24

'''
    print(header + '\n\n'.join(blocks) + '\n}')


if __name__ == '__main__':
    main()
