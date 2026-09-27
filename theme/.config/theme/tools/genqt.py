import os, re
H = os.path.expanduser('~/.dotfiles')
cat_colors = open(f'{H}/qt/.local/share/color-schemes/CatppuccinMocha.colors').read()
cat_kdg = open(f'{H}/qt/.config/kdeglobals').read()
def rgb(h): h=h.lstrip('#'); return ','.join(str(int(h[i:i+2],16)) for i in (0,2,4))
# catppuccin rgb -> role
roles = {'30,30,46':'base','36,36,54':'alt','205,214,244':'text','166,173,200':'sub0','250,179,135':'peach',
 '137,180,250':'blue','203,166,247':'mauve','243,139,168':'red','249,226,175':'yellow','166,227,161':'green',
 '180,190,254':'lavender','24,24,37':'mantle','49,50,68':'s0','69,71,90':'s1','87,74,130':'sel','17,17,27':'crust'}
T = {
 'neo-brutal-light': dict(scheme='NeoBrutalLight', label='Neo-Brutal Light',
   base='#FFFDF8', alt='#F5F1E8', text='#111111', sub0='#5F5B53', peach='#C4561F', blue='#2B63D9', mauve='#7148D6',
   red='#D8412F', yellow='#A86A00', green='#178A4C', lavender='#5B4BC4', mantle='#F5F1E8', s0='#EFEADF', s1='#E3DDCF',
   sel='#FFCF4A', crust='#EAE4D6',
   qt=dict(WindowText='#111111', Button='#EFEADF', Light='#FFFFFF', Midlight='#F5F1E8', Dark='#111111', Mid='#CFC8B8',
     Text='#111111', BrightText='#FFFDF8', ButtonText='#111111', Base='#FFFDF8', Window='#F5F1E8', Shadow='#111111',
     Highlight='#FFCF4A', HighlightedText='#111111', Link='#2B63D9', LinkVisited='#7148D6', AlternateBase='#F5F1E8',
     NoRole='#FFFDF8', ToolTipBase='#FFFDF8', ToolTipText='#111111', PlaceholderText='#808A857B'),
   dis='#8A857B', inhl='#E3DDCF'),
 'neo-brutal-dark': dict(scheme='NeoBrutalDark', label='Neo-Brutal Dark',
   base='#1C1C22', alt='#18181D', text='#EDE8DF', sub0='#8E8A99', peach='#FF9B6B', blue='#7AA7FF', mauve='#C9B8FF',
   red='#FF7A6B', yellow='#FFCF4A', green='#5BD690', lavender='#C9B8FF', mantle='#18181D', s0='#24242B', s1='#2A2A32',
   sel='#FFCF4A', crust='#131318',
   qt=dict(WindowText='#EDE8DF', Button='#24242B', Light='#3A3A44', Midlight='#2A2A32', Dark='#000000', Mid='#18181D',
     Text='#EDE8DF', BrightText='#FFD9CC', ButtonText='#EDE8DF', Base='#1C1C22', Window='#1C1C22', Shadow='#000000',
     Highlight='#FFCF4A', HighlightedText='#111111', Link='#7AA7FF', LinkVisited='#C9B8FF', AlternateBase='#18181D',
     NoRole='#1C1C22', ToolTipBase='#24242B', ToolTipText='#EDE8DF', PlaceholderText='#806B6878'),
   dis='#6B6878', inhl='#3A3A44'),
}
order = 'WindowText Button Light Midlight Dark Mid Text BrightText ButtonText Base Window Shadow Highlight HighlightedText Link LinkVisited AlternateBase NoRole ToolTipBase ToolTipText PlaceholderText'.split()
def argb(h): h=h.lstrip('#'); return '#'+(h if len(h)==8 else 'ff'+h).lower()
def sub(text, t, sel_text_fix=True):
    out = re.sub(r'\b(\d+,\d+,\d+)\b', lambda m: rgb(t[roles[m.group(1)]]) if m.group(1) in roles else m.group(1), text)
    # text drawn ON the selection must be ink, not the scheme's normal text
    out = re.sub(r'(\[Colors:Selection\][^\[]*)', lambda m: re.sub(r'(?m)^(Foreground(?:Normal|Inactive|Active))=.*$', r'\1=' + rgb('#111111'), m.group(1)), out)
    return out
def section_fragment(kdg):
    # the colour-owning parts of kdeglobals: [General]ColorScheme, every [Colors:*], [WM]
    parts = ['[General]\n' + re.search(r'(?m)^ColorScheme=.*$', kdg).group(0) + '\n']
    for m in re.finditer(r'(?ms)^\[(Colors:[^\]]+|WM)\]\n.*?(?=^\[|\Z)', kdg):
        parts.append(m.group(0).rstrip('\n') + '\n')
    return '\n'.join(parts)
os.makedirs(f'{H}/theme/.config/theme/catppuccin-mocha', exist_ok=True)
open(f'{H}/theme/.config/theme/catppuccin-mocha/kdeglobals.ini', 'w').write(section_fragment(cat_kdg))
for name, t in T.items():
    d = f'{H}/theme/.config/theme/{name}'
    frag = sub(section_fragment(cat_kdg), t).replace('ColorScheme=CatppuccinMocha', 'ColorScheme=' + t['scheme'])
    open(f'{d}/kdeglobals.ini', 'w').write(frag)
    cs = sub(cat_colors, t).replace('Name=Catppuccin Mocha', 'Name=' + t['label']).replace('ColorScheme=CatppuccinMocha', 'ColorScheme=' + t['scheme'])
    open(f'{H}/qt/.local/share/color-schemes/{t["scheme"]}.colors', 'w').write(cs)
    q = t['qt']
    act = [argb(q[r]) for r in order]
    dis = [argb(t['dis']) if r in ('WindowText','Text','ButtonText','HighlightedText','ToolTipText') else (argb(t['inhl']) if r=='Highlight' else argb(q[r])) for r in order]
    ina = [argb(t['inhl']) if r=='Highlight' else argb(q[r]) for r in order]
    open(f'{d}/qt6ct-colors.conf', 'w').write(
        f'# {t["label"]} palette for qt6ct (generated alongside the Kvantum theme {t["scheme"]}).\n'
        '# 21 entries in QPalette role order; see qt/.config/qt6ct/colors/catppuccin-mocha.conf.\n'
        '[ColorScheme]\n'
        f'active_colors={", ".join(act)}\ndisabled_colors={", ".join(dis)}\ninactive_colors={", ".join(ina)}\n')
print('ok')
