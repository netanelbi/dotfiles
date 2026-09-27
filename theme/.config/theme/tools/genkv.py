import re, sys, os
src = os.path.expanduser('~/.dotfiles/qt/.config/Kvantum/CatppuccinMocha')
maps = {
 'NeoBrutalLight': dict(
  bg0='#FFFDF8', bg1='#F5F1E8', bg2='#EAE4D6', btn='#EFEADF', btn2='#E3DDCF', mid='#CFC8B8',
  ink='#111111', text='#111111', sub0='#5F5B53', sub1='#3A3833', ov='#8A857B',
  accent='#C9B8FF', accent2='#5B4BC4', pink='#C0408A', hl='#FFCF4A', blue='#2B63D9', white='#111111',
  extra={'#fff': '#111111', '#d7d7d7': '#3A3833', '#d2d2d2': '#3A3833', '#c3c3c3': '#3A3833', '#b4b4b4': '#5F5B53', '#a0a0a0': '#5F5B53', '#969696': '#5F5B53', '#acb1bc': '#5F5B53'},
  comment='Neo-brutal light: cream panels, ink outlines, square corners (generated from CatppuccinMocha)'),
 'NeoBrutalDark': dict(
  bg0='#1C1C22', bg1='#18181D', bg2='#131318', btn='#24242B', btn2='#2A2A32', mid='#3A3A44',
  ink='#EDE8DF', text='#EDE8DF', sub0='#8E8A99', sub1='#B9B4C2', ov='#6B6878',
  dark='#000000', accent='#C9B8FF', accent2='#C9B8FF', pink='#F5A8D8', hl='#FFCF4A', blue='#7AA7FF', white='#FFFFFF',
  comment='Neo-brutal dark: square corners, cream outlines (slick-b) (generated from CatppuccinMocha)'),
}
def table(m):
    return {
     '#1e1e2e': m['bg0'], '#181825': m['bg1'], '#11111b': m['ink'], '#000000': m['ink'],
     '#313244': m['btn'], '#45475a': m['btn2'], '#363849': m['btn2'], '#232334': m['bg1'],
     '#1b1b2a': m['bg1'], '#141420': m['bg2'], '#0b0b12': m['ink'], '#262637': m['btn'],
     '#1a1a28': m['bg1'], '#121220': m['bg2'], '#171724': m['bg2'], '#242436': m['bg1'],
     '#585b70': m['mid'], '#313131': m['btn2'], '#191919': m['mid'],
     '#cba6f7': m['accent'], '#b4befe': m['accent2'], '#9d7cd8': m['accent2'], '#f5c2e7': m['pink'],
     '#574a82': m['hl'], '#9399b2': m['sub0'], '#7f849c': m['ov'], '#cdd6f4': m['text'],
     '#a6adc8': m['sub0'], '#bac2de': m['sub1'], '#6c7086': m['ov'], '#89b4fa': m['blue'],
     '#0582ff': m['blue'], **m.get('extra', {}),
    }
for name, m in maps.items():
    t = table(m)
    rx = re.compile('(?:' + '|'.join(re.escape(k) for k in sorted(t, key=len, reverse=True)) + r')(?![0-9a-fA-F])', re.I)
    sub = lambda s: rx.sub(lambda mo: t[mo.group(0).lower()], s)
    out = os.path.expanduser(f'~/.dotfiles/qt/.config/Kvantum/{name}')
    os.makedirs(out, exist_ok=True)
    kv = open(f'{src}/CatppuccinMocha.kvconfig').read()
    # #11111b in the kvconfig is only ever text ON a fill (menu focus, progress): keep it ink
    kv = sub(kv.replace('#11111b', '#111111'))
    kv = re.sub(r'=white\b', '=' + m['white'], kv)
    kv = re.sub(r'(?m)^comment=.*$', 'comment=' + m['comment'], kv)
    # pressed/toggled/selected states sit on pastel fills: ink text, like the mockup's chips
    kv = re.sub(r'(?m)^(text\.(?:press|toggle)(?:\.inactive)?\.color)=.*$', r'\1=#111111', kv)
    kv = re.sub(r'(?m)^((?:inactive\.)?highlight\.text\.color)=.*$', r'\1=#111111', kv)
    kv = kv.replace('dark.color=black', 'dark.color=' + m.get('dark', m['ink']))
    open(f'{out}/{name}.kvconfig', 'w').write(kv)
    svg = open(f'{src}/CatppuccinMocha.svg').read()
    svg = sub(svg)
    # square corners: zero the small radii on <rect> (radio/round knobs keep theirs)
    def sq(mo):
        el = mo.group(0)
        return re.sub(r'\b(r[xy])="(?:2|2\.5\d*|3|2\.9999983)"', r'\1="0"', el)
    svg = re.sub(r'<rect\b[^>]*>', sq, svg, flags=re.S)
    open(f'{out}/{name}.svg', 'w').write(svg)
    print(name, 'ok')
