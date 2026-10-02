"""Bounded title evidence for a work's parts, not an IP/tag classifier."""
from collections import defaultdict
from dataclasses import dataclass
import hashlib
import re
from authors import PREFIX, normalized, name_key, east_asian
import relaxed

GENERIC = {'comic','comics','illustrations','collection','作品集','合集','総集編',
           '总集篇','総集篇','まとめ','落書き','らくがき','短篇','短編','無題','untitled'}
NUMBER = r'[0-9一二三四五六七八九十百零〇]+(?:\.[0-9]+)?'
MARKER = r'(?:前[編篇]|後[編篇]|后[编篇]|中[編篇]|[上中下][巻卷]|完結[編篇]|完结篇|続[編篇]|续[编篇])'
EXTRA = r'(?:番外(?:[編篇])?|後日談|后日谈|特[別别][編篇]|特[別别]篇|特别章|外伝|外传|續篇|续篇|続編|続篇|epilogue|after\s*story|extra(?:\s*chapter)?|special(?:\s*chapter)?)'
ENGLISH = r'(?:vol(?:ume)?\.?|v\.?|ch(?:apter)?\.?|part|episode|ep\.?)'
WRAPPED_PART = re.compile(r'^(?:第?\s*'+NUMBER+r'\s*[巻卷話话章集部篇]|'+ENGLISH+r'\s*'+NUMBER+r'|'+MARKER+r'|'+EXTRA+r')$',re.I)
EXPLICIT = [
    re.compile(r'(?<![A-Za-z])'+ENGLISH+r'\s*('+NUMBER+r')(?=$|\s|[-:：～~])',re.I),
    re.compile(r'第\s*('+NUMBER+r')\s*[巻卷話话章集部篇]'),
    re.compile(r'('+NUMBER+r')\s*[巻卷話话章]'),
    re.compile(MARKER+r'$'),
    re.compile(r'\s+([IVX]{1,6})$',re.I),
]
BARE = re.compile(r'('+NUMBER+r')(?=\s*(?:$|[-:：～~]))')
DATE = re.compile(r'(?<!\d)(?:19|20)\d{2}[-./_]\d{1,2}(?:[-./_]\d{1,2})?(?!\d)')
EDITION = re.compile(r'(?:chinese|english|japanese|中国翻訳|中国語|日本語|汉化|漢化|中文|翻译|翻譯|digital|dl版|再版|修正版|改訂版|修订版|完全版|無修正|无修正|decensored)',re.I)


@dataclass(frozen=True)
class ParsedSeries:
    root: str
    part: str = ''
    subtitle: str = ''
    edition: str = ''
    candidate_root: str = ''


def parse_series_title(title):
    text=normalized(title[:1024]).translate(str.maketrans({'【':'[','】':']'}))
    if text.startswith('('):
        end=text.find(')')
        if 0<end<100 and text[end+1:].lstrip().startswith('['):text=text[end+1:].lstrip()
    for _ in range(5):
        m=PREFIX.match(text)
        if not m:break
        text=text[m.end():].strip()
    # Protect dates BEFORE attempting to strip any decimal/trailing number.
    if DATE.search(text):return None
    part='';extra_part='';notes=[];editions=[]
    for _ in range(8):
        suffix=re.search(r'\s*(?:\[([^\[\]]{1,256})\]|\(([^()]{1,256})\))\s*$',text)
        if not suffix:break
        value=(suffix[1] or suffix[2]).strip()
        if re.fullmatch(EXTRA,value,re.I):extra_part=value
        elif WRAPPED_PART.fullmatch(value):part=value
        else:
            notes.append(value)
            if EDITION.search(value):editions.append(value[:96])
        text=text[:suffix.start()].strip()
    text=text.split('|',1)[0].strip()
    sequel=re.match(r'^(続|续)\s*[・:：\-]\s*',text)
    if sequel:part=sequel[1];text=text[sequel.end():].strip()
    subtitle=''
    extra=re.search(r'(?:\s+|[-:：～~]|(?<=[\u3040-\u9fff]))('+EXTRA+r')$',text,re.I)
    if extra:extra_part=extra[1];text=text[:extra.start()].rstrip(' -:：~～')
    for pattern in EXPLICIT:
        m=pattern.search(text)
        if m:
            part=m[0].strip();subtitle=text[m.end():].strip(' -:：~～')
            text=text[:m.start()].rstrip(' -_:：~～');break
    else:
        matches=list(BARE.finditer(text))
        if matches:
            m=matches[0];number=m[1];prefix=text[:m.start()]
            # Bare years / 007 / Area51 are not sufficient volume evidence.
            year=number.isdecimal() and 1900<=int(number)<=2099
            leading_zero=len(number)>1 and number.startswith('0') and number[1].isdigit()
            attached=bool(prefix and prefix[-1].isascii() and prefix[-1].isalnum())
            if not (year or leading_zero or attached):
                part=number;subtitle=text[m.end():].strip(' -:：~～')
                text=prefix.rstrip(' -_:：~～')
    if extra_part:part=(part+' · ' if part else '')+extra_part
    if not 2<=len(text)<=192 or name_key(text) in GENERIC or (not part and not text.strip('0123456789 .-')):
        return None
    # EH source/IP suffixes remain notes, never grouping keys of their own.
    # Keep the full root for strict matching. An explicit subtitle separator
    # supplies a one-hop expanded key, not an identity alias or fuzzy prefix.
    candidate=''
    split=re.match(r'^(.+?)(?:\s+[-–—]\s+|\s*[:：～~]\s*)(.+?)\s*[～~]?$',text)
    if not part and split:
        base=split[1].strip();tail=split[2].strip(' ~～')
        if 2<=len(base)<=192 and name_key(base) not in GENERIC and tail:
            candidate=base;subtitle=tail
    return ParsedSeries(text,part,subtitle or ' / '.join(reversed(notes)), ' / '.join(reversed(editions))[:96],candidate)


def series_title(title):
    parsed=parse_series_title(title)
    return (parsed.root,bool(parsed.part)) if parsed else None


class SeriesIndex:
    # More valid credits can also create more ordinary series. Keep the total
    # metadata estimate bounded; candidate-only structures have their own cap.
    budget=24*1024*1024
    def __init__(self,books,authors,previous=None):
        if not 0<len(books)<=20000:raise ValueError('series_index_limit')
        self.parsed={};self.parsed_count=0;self.order={b['id']:i for i,b in enumerate(books)}
        for b in books:
            gid=b['id'];saved=previous.parsed.get(gid) if previous else None
            if saved and saved[:2]==(b['title'],b['directory']):row=saved
            else:
                folder=b['directory'];other=folder[len(gid)+1:] if folder.startswith(gid+'-') else ''
                row=(b['title'],folder,parse_series_title(b['title']),parse_series_title(other))
                self.parsed_count+=1
            self.parsed[gid]=row
        self.authors_structure=authors.structure
        self.reordered_only=bool(previous and not self.parsed_count and self.parsed.keys()==previous.parsed.keys()
                                 and previous.authors_structure is authors.structure)
        if self.reordered_only:
            for attr in ('choices','group_for','labels','part_labels','aliases','cost',
                         'expanded_choices','expanded_group_for','expanded_labels','expanded_aliases','group_notes'):
                setattr(self,attr,getattr(previous,attr))
            self.relaxed=previous.relaxed
            self.group_members={g:tuple(sorted(ids,key=self.order.__getitem__)) for g,ids in previous.group_members.items()}
            self.members={i:self.group_members[g] for i,g in self.group_for.items()}
            self.expanded_members={g:tuple(sorted(ids,key=self.order.__getitem__)) for g,ids in previous.expanded_members.items()}
            return
        # Intern repeated roots/part notes and identical parsed records. A
        # ten-thousand-book snapshot must not keep ten thousand copies of
        # the same title root merely to avoid reparsing it on reorder.
        texts={};parsed_records={}
        for gid,row in self.parsed.items():
            parsed=[]
            for p in row[2:]:
                if p:
                    p=ParsedSeries(*(texts.setdefault(v,v) for v in (p.root,p.part,p.subtitle,p.edition,p.candidate_root)))
                    p=parsed_records.setdefault(p,p)
                parsed.append(p)
            self.parsed[gid]=row[:2]+tuple(parsed)
        rows=[];peers=defaultdict(set);fallback=set()
        for gid,row in self.parsed.items():
            title,other=row[2:];creators=authors.creators.get(gid,())
            if not title and other and not DATE.search(normalized(row[0][:1024])):title=other;fallback.add(gid)
            if not title or not creators:continue
            rows.append((gid,title,creators))
            if other and east_asian(title.root)!=east_asian(other.root):
                jp,latin=(name_key(title.root),name_key(other.root)) if east_asian(title.root) else (name_key(other.root),name_key(title.root))
                for creator in creators:peers[(creator,latin)].add(jp)
        groups=defaultdict(list);names=defaultdict(set);numbered=set();by_book=defaultdict(list);selectors={}
        wide=defaultdict(list);wide_names=defaultdict(set);wide_books=defaultdict(list);source_parts={};wide_roots={}
        for gid,title,creators in rows:
            for source_id,creator in zip(authors.choices[gid],creators):
                base=name_key(title.root);alternates=peers.get((creator,base),set())
                if not east_asian(title.root) and len(alternates)==1:base=next(iter(alternates))
                group=(creator,base)
                # External selection stays anchored to its source credit/root.
                selector=(source_id,name_key(title.root))
                if selector not in selectors:selectors[selector]=hashlib.sha256(('localshelf-series-v2\n'+selector[0]+'\n'+selector[1]).encode()).hexdigest()
                identity=selectors[selector]
                if gid not in fallback:
                    groups[group].append(gid);by_book[gid].append((identity,group))
                    names[group].add(title.root)
                    if title.part:numbered.add(group)
                root=name_key(title.candidate_root) if title.candidate_root else base
                expanded=(creator,root)
                expanded_selector=(source_id,name_key(title.candidate_root or title.root))
                if expanded_selector not in selectors:
                    selectors[expanded_selector]=hashlib.sha256(('localshelf-series-v2\n'+expanded_selector[0]+'\n'+expanded_selector[1]).encode()).hexdigest()
                wide[expanded].append(gid);wide_books[gid].append((selectors[expanded_selector],expanded))
                wide_names[expanded].add(title.candidate_root or title.root)
                source_parts[gid]=title;wide_roots[(gid,expanded)]=base
        self.group_members={g:tuple(ids) for g,ids in groups.items() if len(ids)>1 and g in numbered}
        labels={g:sorted(names[g],key=lambda n:(not east_asian(n),name_key(n),n))[0] for g in self.group_members}
        # Hash each group's member tuple ONCE, not once per book in it.
        signatures={};representative={}
        for g,ids in self.group_members.items():
            signature=(ids,name_key(labels[g]))
            representative[g]=signatures.setdefault(signature,g)
        self.choices={};self.group_for={};self.labels={};choice_records={}
        for gid,entries in by_book.items():
            seen=set();choices=[]
            for identity,g in entries:
                if g not in self.group_members:continue
                representative_id=representative[g]
                if representative_id in seen:continue
                seen.add(representative_id);choices.append(identity)
                self.group_for[identity]=g;self.labels[identity]=labels[g]
            if choices:
                choices=tuple(choices);self.choices[gid]=choice_records.setdefault(choices,choices)
        self.members={i:self.group_members[g] for i,g in self.group_for.items()}
        self.part_labels={gid:p.part[:96] for gid,p in source_parts.items() if p.part}
        group_aliases={g:tuple(sorted(names[g]-{labels[g]}))[:8] for g in self.group_members}
        self.aliases={i:group_aliases[g] for i,g in self.group_for.items()}
        self.expanded_members={g:tuple(ids) for g,ids in wide.items() if len(ids)>1}
        self.expanded_labels={g:sorted(wide_names[g],key=lambda n:(not east_asian(n),name_key(n),n))[0] for g in self.expanded_members}
        self.expanded_aliases={g:tuple(sorted(wide_names[g]-{self.expanded_labels[g]}))[:8] for g in self.expanded_members}
        self.expanded_choices={};self.expanded_group_for={};self.group_notes={}
        signatures={};representative={}
        for group,ids in self.expanded_members.items():
            representative[group]=signatures.setdefault((ids,name_key(self.expanded_labels[group])),group)
            has_subtitle=any(source_parts[gid].candidate_root for gid in ids)
            numbered_roots={wide_roots[(gid,group)] for gid in ids if source_parts[gid].part and gid not in fallback}
            versions=defaultdict(set)
            for gid in ids:
                p=source_parts[gid]
                versions[(name_key(p.root),name_key(p.part))].add(name_key(p.edition))
            notes={}
            for gid in ids:
                p=source_parts[gid];root=wide_roots[(gid,group)]
                if gid in fallback:reason='directory'
                elif len(versions[(name_key(p.root),name_key(p.part))])>1:reason='edition'
                elif has_subtitle:reason='seriesSubtitle'
                elif root not in numbered_roots:reason='seriesTitle'
                else:continue
                notes[gid]=reason
            self.group_notes[group]=notes
        wide_choice_records={}
        for gid,entries in wide_books.items():
            seen=set();choices=[]
            for identity,g in entries:
                if g not in self.expanded_members or representative[g] in seen:continue
                seen.add(representative[g]);choices.append(identity);self.expanded_group_for[identity]=g
            if choices:
                value=tuple(choices);self.expanded_choices[gid]=wide_choice_records.setdefault(value,value)
        self.cost=sum(512+len(ids)*64 for ids in self.group_members.values())
        self.cost+=len(self.choices)*64+sum(64+len(ids)*16 for ids in choice_records)
        self.cost+=sum(256+2*len(label.encode()) for label in self.labels.values())
        self.cost+=len(self.parsed)*128+len(parsed_records)*96
        self.cost+=sum(64+2*len(v.encode()) for v in texts)
        self.cost+=len(self.part_labels)*96  # values normally share parsed part strings
        self.cost+=sum(96+sum(64+2*len(v.encode()) for v in values) for values in group_aliases.values())
        self.cost+=sum(192+len(ids)*16+len(self.group_notes[g])*80 for g,ids in self.expanded_members.items())
        self.cost+=len(self.expanded_choices)*40+sum(64+len(v)*16 for v in wide_choice_records)+len(self.expanded_group_for)*128
        self.cost+=sum(64+2*len(v.encode()) for v in self.expanded_labels.values())
        self.relaxed,extra_cost=relaxed.build(self,authors)
        if extra_cost>8*1024*1024:raise ValueError('series_candidate_limit')
        self.cost+=extra_cost
        if self.cost>self.budget:raise ValueError('series_index_limit')

    def relaxed_options(self,gid):
        return [r[0] for r in relaxed.choices(self,gid)]

    def relaxed_details(self,gid,identity):
        for result in relaxed.choices(self,gid):
            if result[0]['id']==identity:return result
        raise KeyError(identity)

    def options(self,gid,expanded=False):
        if expanded:return [self.details(gid,i)[0] for i in self.expanded_choices.get(gid,())]
        return [dict(id=i,name=self.labels[i],matchKind='series',count=len(self.members[i]),aliases=list(self.aliases[i])) for i in self.choices.get(gid,())]

    def details(self,gid,identity):
        if identity not in self.expanded_choices.get(gid,()):raise KeyError(identity)
        group=self.expanded_group_for[identity];ids=self.expanded_members[group];notes=self.group_notes[group]
        option=dict(id=identity,name=self.expanded_labels[group],matchKind='series',count=len(ids),
                    aliases=list(self.expanded_aliases[group]),possibleCount=len(notes),evidenceVersion=3)
        return option,ids,frozenset(notes)

    def selection(self,gid,identity):
        if identity not in self.choices.get(gid,()):raise KeyError(identity)
        return next(o for o in self.options(gid) if o['id']==identity),self.members[identity]
