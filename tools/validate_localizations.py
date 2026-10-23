"""Check source coverage and printf contracts, without mistaking fallback for translation."""
import re
from generate_project import LANGUAGES, ROOT, load_translations

translations = load_translations()
base = translations['en']
failures = []
for language in LANGUAGES:
    values = translations.get(language,{})
    missing = set(base)-set(values)
    extra = set(values)-set(base)
    if missing or extra: failures.append(f'{language}: missing={sorted(missing)}, extra={sorted(extra)}')
    for key,value in values.items():
        if not value.strip(): failures.append(f'{language}:{key} is empty')
        if re.findall(r'%(?:\d+\$)?[diu@sf]',value) != re.findall(r'%(?:\d+\$)?[diu@sf]',base.get(key,'')):
            failures.append(f'{language}:{key} printf parameters differ')
    print(f'{language}: {len(set(values)&set(base))}/{len(base)} strings')
# Code-literal translation references; dynamic outcome/sound keys validated above.
for folder in ['App','Shared','Extensions']:
    for path in (ROOT/folder).rglob('*.swift'):
        for key in re.findall(r'\b(?:tr|tf)\("([^"\n]+)"\s*[,)]',path.read_text()):
            if key not in base: failures.append(f'{path.relative_to(ROOT)}: unknown key {key}')
if failures: raise SystemExit('\n'.join(failures))
print('PASS: 20 languages, complete keys, printf contracts, and literal lookups. Native review is still required.')
