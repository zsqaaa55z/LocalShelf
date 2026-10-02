"""Opt-in, one-hop title candidates. No media IO, identity unions or fuzzy names.

Exact normalized roots use dictionary lookups. One-character title comparisons
are limited to 256 distinct roots of the SAME confirmed author per query. Large
author groups retain exact/punctuation matches and skip fuzzy work entirely.
The data consists only of typed metadata and shares the related disk snapshot.
"""
from collections import defaultdict
import hashlib
import re
import unicodedata
from authors import east_asian, name_key

GENERIC={'comic','comics','collection','illustrations','作品集','合集','総集編',
         '总集篇','総集篇','まとめ','落書き','らくがき','短篇','短編','無題','untitled'}
LANGUAGES=(('zh',r'chinese|中国翻訳|中国語|汉化|漢化|中文|翻译|翻譯'),
           ('en',r'english'),('ja',r'japanese|日本語'))
MAX_FUZZY_ROOTS=256


def title_key(value):
    text=name_key(value)
    # Numeric and letter content is preserved: Area51 is not Area52.
    return ''.join(chr(ord(c)-0x60) if '\u30a1'<=c<='\u30f6' else c
                   for c in text if not c.isspace() and not unicodedata.category(c).startswith('P'))


def close_title(a,b):
    """At most one insertion/deletion/substitution; no substring or token set."""
    if a==b:return True
    if not 6<=min(len(a),len(b))<=96 or max(len(a),len(b))>96 or abs(len(a)-len(b))>1:return False
    if re.findall(r'\d+',a)!=re.findall(r'\d+',b):return False
    i=j=errors=0
    while i<len(a) and j<len(b):
        if a[i]==b[j]:i+=1;j+=1;continue
        errors+=1
        if errors>1:return False
        if len(a)>=len(b):i+=1
        if len(b)>=len(a):j+=1
    return errors+(i<len(a) or j<len(b))<=1


def roots(parsed):
    if parsed is None:return ()
    return tuple(dict.fromkeys(k for k in (title_key(parsed.root),title_key(parsed.candidate_root))
                              if len(k)>=3 and k not in GENERIC))


def build(index,authors):
    rows={};sources={};buckets=defaultdict(lambda:defaultdict(list));weak=defaultdict(lambda:defaultdict(list))
    shared_keys={};shared_sources={}
    evidence=defaultdict(list)
    for gid,row in index.parsed.items():
        # Folder fallback follows the existing date guard, never overrides a
        # successfully parsed display title (including an unrelated title).
        parsed=row[2]
        if parsed is None and row[3] and not re.search(r'(?:19|20)\d{2}[-./_]\d{1,2}',row[0]):parsed=row[3]
        keys=roots(parsed)
        if not keys:continue
        keys=shared_keys.setdefault(keys,keys)
        strong=tuple(zip(authors.choices.get(gid,()),authors.creators.get(gid,())))
        inferred=tuple((i,authors.known_group_for[i]) for i in authors.known_choices.get(gid,()))
        if not strong and not inferred:continue
        rows[gid]=(parsed,keys)
        credits=tuple((i,g,0) for i,g in strong)+tuple((i,g,1) for i,g in inferred)
        sources[gid]=shared_sources.setdefault(credits,credits)
        for _,group,is_weak in sources[gid]:
            table=weak if is_weak else buckets
            for key in keys:table[group][key].append(gid)
        # Reverse evidence is deliberately stronger than title resemblance:
        # same LONG full root, same explicit part, differing translation edition,
        # sole credited artists, one East-Asian name and one Roman spelling.
        if len(strong)==1 and parsed.part and not parsed.candidate_root and len(keys[0])>=(6 if east_asian(keys[0]) else 12):
            group=strong[0][1]
            if group in authors.ambiguous_names:continue
            language={code for code,pattern in LANGUAGES if re.search(pattern,parsed.edition,re.I)}
            if len(language)==1:
                signature=(keys[0],name_key(parsed.part))
                evidence[signature].append((group,next(iter(language))))
    proposed=defaultdict(set)
    for entries in evidence.values():
        unique=set(entries)
        # A widely shared title or multiple conflicting credits is not evidence
        # to compare every person with every other person.
        groups={g for g,_ in unique}
        if len(groups)!=2:continue
        a,b=sorted(groups)
        if east_asian(a)==east_asian(b):continue
        if not east_asian(a):a,b=b,a
        if {lang for g,lang in unique if g==a}&{lang for g,lang in unique if g==b}:continue
        proposed[b].add(a)
    peers=defaultdict(set)
    for roman,japanese in proposed.items():
        if len(japanese)!=1:continue
        target=next(iter(japanese));peers[roman].add(target);peers[target].add(roman)
    near={g:authors.nearby_groups(g) for g in buckets}
    data={'rows':rows,'sources':sources,
          'buckets':{g:{k:tuple(ids) for k,ids in values.items()} for g,values in buckets.items()},
          'weak':{g:{k:tuple(ids) for k,ids in values.items()} for g,values in weak.items()},
          'near':near,'work_peers':{g:tuple(sorted(v)) for g,v in peers.items() if len(v)<=8}}
    # Symmetric, direct evidence only. A cap must not retain a one-way edge.
    data['work_peers']={g:tuple(p for p in v if g in data['work_peers'].get(p,())) for g,v in data['work_peers'].items()}
    cost=len(rows)*96+len(sources)*32+sum(64+len(v)*64 for v in shared_sources)
    cost+=sum(32+len(v)*16 for v in shared_keys)
    for table in (data['buckets'],data['weak']):
        cost+=sum(96+sum(80+2*len(k.encode())+len(ids)*16 for k,ids in values.items()) for values in table.values())
    cost+=sum(64+len(v)*16 for v in near.values())+sum(64+len(v)*16 for v in data['work_peers'].values())
    return data,cost


def choices(index,gid):
    data=index.relaxed
    legacy=[]
    for identity in index.expanded_choices.get(gid,()):
        option,ids,possible=index.details(gid,identity)
        legacy.append((option,ids,possible,index.group_notes[index.expanded_group_for[identity]]))
    if gid not in data['rows']:return legacy
    parsed,keys=data['rows'][gid];results=[];seen=set()
    for source,group,is_weak in data['sources'][gid]:
        identity=hashlib.sha256(('localshelf-series-v2\n'+source+'\n'+name_key(parsed.candidate_root or parsed.root)).encode()).hexdigest()
        old_group=index.expanded_group_for.get(identity)
        baseline=frozenset(index.expanded_members.get(old_group,())) if identity in index.expanded_choices.get(gid,()) else frozenset()
        ids=set(baseline);notes=dict(index.group_notes.get(old_group,{})) if baseline else {}
        same=data['buckets'].get(group,{})
        for key in keys:
            for other in same.get(key,()):
                ids.add(other)
                if other not in baseline:notes[other]='authorSeries' if is_weak else 'seriesVariant'
        if not is_weak and len(same)<=MAX_FUZZY_ROOTS:
            for other_key,members in same.items():
                if other_key in keys or not any(close_title(k,other_key) for k in keys):continue
                # A small spelling change without any volume/part evidence is
                # not sufficient to call two unrelated stories a series.
                for other in members:
                    if parsed.part or data['rows'][other][0].part:
                        ids.add(other)
                        if other not in baseline:notes[other]='seriesVariant'
        # Author and series uncertainty do not multiply: weak author evidence
        # requires an exact normalized root AND part evidence, never fuzzy roots.
        nearby=() if is_weak else data['near'].get(group,())+data['work_peers'].get(group,())
        tables=[data['weak'].get(group,{})]
        tables.extend(data['buckets'].get(p,{}) for p in nearby)
        for table in tables:
            for key in keys:
                if len(key)<4:continue
                for other in table.get(key,()):
                    if parsed.part or data['rows'][other][0].part:
                        ids.add(other)
                        if other not in baseline:notes[other]='authorSeries'
        # Inferred sources are themselves possible, but do not teach an alias.
        if is_weak and any(parsed.part or data['rows'][other][0].part for other in ids):
            ids.add(gid);notes[gid]='authorSeries'
        elif is_weak:continue
        if len(ids)<2:continue
        if gid not in ids:ids.add(gid);notes[gid]='seriesVariant'
        ordered=tuple(sorted(ids,key=index.order.__getitem__))
        signature=(ordered,name_key(parsed.candidate_root or parsed.root))
        if signature in seen:continue
        seen.add(signature)
        option=dict(id=identity,name=index.expanded_labels.get(old_group,parsed.candidate_root or parsed.root),
                    matchKind='series',count=len(ids),aliases=list(index.expanded_aliases.get(old_group,())),
                    possibleCount=len(notes),evidenceVersion=3)
        results.append((option,ordered,frozenset(notes),notes))
    identities={r[0]['id'] for r in results}
    results.extend(r for r in legacy if r[0]['id'] not in identities)
    return results
