"""Bounded title-credit index. Naming evidence, NOT authoritative artist tags.

Only published metadata is processed. Never opens directories or media files.
No guessed kanji readings, edit distance, circle-based identity union or alias chains.
"""
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import re
import unicodedata

MARKERS = frozenset(('pixiv', 'patreon', 'fanbox', 'pixiv fanbox', 'fantia',
    'twitter', 'x', 'gumroad', 'ai', 'ai generated', 'ai生成', '3d', '同人誌',
    'chinese', 'english', 'korean', 'japanese', '中国翻訳', '中国語', '日本語',
    'digital', 'dl版', '汉化', '漢化', '中文', '中文翻译', '中文翻譯', '全彩',
    'decensored', '無修正', 'colorized', 'sample', 'textless', 'incomplete', 'ongoing'))
COLLECTIVE = frozenset(('anthology', 'アンソロジー', '合集', '合同誌', 'various',
                        'various artists', 'unknown', '不明', '佚名'))
EVENT = re.compile(r'^(?:c\d+|comic1|comitia|コミティア|例大祭|秋季例大祭|サンクリ|'
                   r'こみトレ|コミトレ|コミケ|コミックマーケット|砲雷撃戦|歌姫庭園|ff\d+)', re.I)
PREFIX = re.compile(r'^\[([^\[\]]{1,256})\]')
CIRCLE_QUALIFIERS = frozenset(('仮','仮称','暫定','暂定'))


def normalized(value):
    return ' '.join(unicodedata.normalize('NFKC', value).split())


def key(value):
    value = normalized(value).casefold()
    # Roman-name layout variants, not guessed kanji readings or edit distance.
    if re.fullmatch(r"[a-z0-9 _.'’\-āēīōū]+", value) and len(value)>=3:
        value = value.translate(str.maketrans({'ā':'aa','ē':'ee','ī':'ii','ō':'ou','ū':'uu'}))
        return re.sub(r"[ _.'’\-]", '', value)
    return value


def variant_keys(value):
    """Bounded spelling buckets. Never promote these keys to identity."""
    original=normalized(value).casefold()
    value=key(value)
    keys={value}
    if re.fullmatch(r'[a-z0-9]+',value) and len(value)>=3:
        # Only documented long-vowel spellings: plain o is NOT a long vowel.
        keys.add('roman:'+value.replace('oo','ou'))
    if re.search(r'[\u3041-\u3096\u30a1-\u30f6]',value):
        keys.add('kana:'+''.join(chr(ord(c)-0x60) if '\u30a1'<=c<='\u30f6' else c for c in value))
    if re.fullmatch(r'[\u3040-\u30ff\u3400-\u9fff\s・·]+',original):
        compact=re.sub(r'[\s・·]','',original)
        if len(compact)>=3:
            keys.add('jp-layout:'+''.join(chr(ord(c)-0x60) if '\u30a1'<=c<='\u30f6' else c for c in compact))
    words=original.split()
    if 2<=len(words)<=4 and all(re.fullmatch(r'[a-zāēīōū]{2,32}',w) for w in words):
        keys.add('roman-order:'+' '.join(sorted(key(w) for w in words)))
    return keys


def name_key(value):
    """Identity normalization: layout/romanization similarity is NOT identity."""
    return normalized(value).casefold()


def author_id(value):
    # A selector is anchored to the source spelling, not the preferred label.
    # Learning a Japanese alias cannot change this token, even after restart.
    return hashlib.sha256(('localshelf-author-v2\n'+value).encode()).hexdigest()


def metadata(value):
    return normalized(value).casefold() in MARKERS or any(s in value for s in
        ('汉化', '漢化', '翻訳', '翻译', '翻譯', '机翻', '機翻'))


def safe_name(value):
    return (0 < len(value) <= 128 and len(value.encode()) <= 384
            and not metadata(value) and normalized(value).casefold() not in COLLECTIVE
            and not any(unicodedata.category(c).startswith('C') for c in value)
            and not any(c in value for c in '[]()<>|/\\')
            and not re.search(r'(?:https?:|www\.|\d{4}[-/.]\d{1,2})', value, re.I))


@dataclass(frozen=True)
class Credit:
    artists: tuple = ()
    circle: str = ''
    untyped: str = ''
    aliases: tuple = ()  # Explicit (primary, alternate) pairs, not coauthors.


def credited_names(raw):
    """Parse explicit alias syntax before coauthor separators; at most 8 names."""
    marked=re.fullmatch(r'(.+?)\s*\((?:旧名|舊名|別名|别名|原名|旧ペンネーム|aka|a\.k\.a\.|alias|formerly)\s*[:：]?\s*(.+?)\)',raw,re.I)
    if not marked:
        marked=re.fullmatch(r'(.+?)\s+(?:aka|a\.k\.a\.|formerly)\s+(.+)',raw,re.I)
    if marked:
        primary,alternate=(n.strip() for n in marked.groups())
        if safe_name(primary) and safe_name(alternate):return (primary,),((primary,alternate),)
        return (),()
    # Slash means an alias only for a single East-Asian / Latin pair.
    bilingual=re.fullmatch(r'([^/()]+)\s*/\s*([^/()]+)',raw)
    if bilingual:
        a,b=(n.strip() for n in bilingual.groups())
        if safe_name(a) and safe_name(b) and east_asian(a)!=east_asian(b):
            primary,alternate=(a,b) if east_asian(a) else (b,a)
            return (primary,),((primary,alternate),)
        return (),()
    names=tuple(dict.fromkeys(n.strip() for n in re.split(r'[,、×]|\s+[+&]\s+',raw)))
    if 1<=len(names)<=8 and all(safe_name(n) for n in names):return names,()
    return (),()


def parentheses(text):
    """Bounded balanced outer groups, preserving brackets inside a circle name."""
    depth=0;start=0;groups=[]
    for index,char in enumerate(text):
        if char=='(':
            if depth==0:start=index
            depth+=1
            if depth>4:return None
        elif char==')':
            depth-=1
            if depth<0:return None
            if depth==0:groups.append((start,index))
    return None if depth else groups


def safe_circle(value):
    groups=parentheses(value)
    if groups is None or not safe_name(value.replace('(','').replace(')','')):return False
    # Separated author-looking groups are ambiguous, not part of a circle name.
    return all(start>0 and (not value[start-1].isspace() or value[start+1:end].strip() in CIRCLE_QUALIFIERS)
               for start,end in groups)


def prefix_text(title):
    """One bounded credit area, never the work title/IP/translator suffix."""
    if not isinstance(title,str) or any(unicodedata.category(c).startswith('C') for c in title[:512]):return ''
    rest=normalized(title[:512]).translate(str.maketrans({'【':'[','】':']'}))
    if rest.startswith('('):
        end=rest.find(')')
        if 0<end<100 and (EVENT.match(rest[1:end]) or rest[end+1:].lstrip().startswith('[')):
            rest=rest[end+1:].lstrip()
    for _ in range(5):
        match=PREFIX.match(rest)
        if not match:return ''
        text=match[1].strip()
        if normalized(text).casefold() in COLLECTIVE:return ''
        if metadata(text):rest=rest[match.end():].lstrip();continue
        return text
    return ''


def credit_tokens(title):
    """Exact-name candidates only; not identities, alias evidence or substrings."""
    text=prefix_text(title)
    if not text or re.search(r'(?:他|ほか|et al|etc\.|合同|anthology|アンソロジー|翻訳|翻译|翻譯|译者|訳者|translator)',text,re.I):return ()
    if parentheses(text) is None:return ()
    # No fuzzy search across authors. Split a maximum of 256 prefix characters
    # into bounded name-sized components, then use exact dictionary lookups.
    parts=re.split(r'[()|/;,、×+&:：]',text)
    if len(parts)>32:return ()
    tokens=tuple(dict.fromkeys(name_key(p.strip()) for p in parts if safe_name(p.strip())))
    return tuple(n for n in tokens if len(n)>=(2 if east_asian(n) else 3))


def parse_credit(title):
    # Do not normalize an entire untrusted 16 KiB title for a short prefix.
    if not isinstance(title, str) or any(unicodedata.category(c).startswith('C') for c in title[:512]):
        return Credit()
    rest = normalized(title[:512]).translate(str.maketrans({'【':'[', '】':']'}))
    if rest.startswith('('):
        end = rest.find(')')
        if 0 < end < 100 and (EVENT.match(rest[1:end]) or rest[end+1:].lstrip().startswith('[')):
            rest = rest[end+1:].lstrip()
    for _ in range(5):
        match = PREFIX.match(rest)
        if not match:
            # Common imageset prefix: creator followed by an unambiguous date.
            dated=re.match(r'^([^\[\]()]{1,64}?)\s+20\d{2}[._/-]\d{1,2}(?:\D|$)',rest)
            if dated and safe_name(dated[1].strip()): return Credit(untyped=dated[1].strip())
            return Credit()
        text = match[1].strip()
        # An anthology marker is not permission to interpret a later bracket
        # (perhaps a title or translator) as its sole author.
        if normalized(text).casefold() in COLLECTIVE: return Credit()
        if metadata(text):
            rest = rest[match.end():].lstrip()
            continue
        names,aliases=credited_names(text)
        if aliases:return Credit(artists=names,aliases=aliases)
        groups=parentheses(text)
        if groups and groups[-1][1]==len(text)-1:
            start,end=groups[-1]
            circle,raw=text[:start].strip(),text[start+1:end].strip()
            if raw in CIRCLE_QUALIFIERS and safe_circle(text):return Credit(untyped=text)
            if not safe_circle(circle) or re.search(r'(?:他|ほか|et al|etc\.)', raw, re.I): return Credit()
            artists,aliases=credited_names(raw)
            if not artists:return Credit()
            return Credit(artists=artists,circle=circle,aliases=aliases)
        if 1<len(names)<=8 and all(safe_name(n) for n in names): return Credit(artists=names)
        if safe_name(text): return Credit(untyped=text)
        return Credit()
    return Credit()


def east_asian(value):
    return any('\u3040' <= c <= '\u30ff' or '\u3400' <= c <= '\u9fff' for c in value)


class AuthorIndex:
    """One current snapshot; cost accounting is bounded, not an RSS promise."""
    budget = 16*1024*1024

    def __init__(self, books, previous=None):
        if not 0 < len(books) <= 20000: raise ValueError('author_index_limit')
        self.parsed = {}
        self.fallback_tokens = {}
        self.parsed_count = 0
        for book in books:
            gid, title, directory = book['id'], book['title'], book['directory']
            saved = previous.parsed.get(gid) if previous else None
            if saved and saved[:2] == (title, directory): row = saved
            else:
                folder = directory[len(gid)+1:] if directory.startswith(gid+'-') else ''
                row = (title, directory, parse_credit(title), parse_credit(folder))
                self.parsed_count += 1
            self.parsed[gid] = row
            if saved and saved[:2]==(title,directory):tokens=previous.fallback_tokens[gid]
            else:
                tokens=tuple(credit_tokens(value) if credit==Credit() else ()
                             for value,credit in ((title,row[2]),(folder,row[3])))
            self.fallback_tokens[gid]=tokens
        self.order = {b['id']:i for i,b in enumerate(books)}
        self.reordered_only = bool(previous and not self.parsed_count and self.parsed.keys()==previous.parsed.keys())
        self.relationships_reused=bool(previous and self.parsed.keys()==previous.parsed.keys() and
            (self.reordered_only or all(row[2:]==previous.parsed[gid][2:] and self.fallback_tokens[gid]==previous.fallback_tokens[gid] for gid,row in self.parsed.items())))
        if self.relationships_reused:
            # Reuse immutable naming relationships. Only member order changes.
            for attr in ('choices','labels','kinds','spellings','group_for','creators',
                         'group_loose','loose_groups','alias_pairs','ambiguous_names','structure','cost',
                         'candidate_members','candidate_choices','candidate_group_for','alias_support',
                         'known_members','known_choices','known_group_for'):
                setattr(self,attr,getattr(previous,attr))
            self.group_members={g:tuple(sorted(ids,key=self.order.__getitem__)) for g,ids in previous.group_members.items()}
            self.members={i:self.group_members[g] for i,g in self.group_for.items() if g in self.group_members}
            if not self.reordered_only:
                self.cost+=sum(2*(len(row[0].encode())+len(row[1].encode())-len(previous.parsed[gid][0].encode())-len(previous.parsed[gid][1].encode())) for gid,row in self.parsed.items())
                if self.cost>self.budget:raise ValueError('author_index_limit')
            return
        self.structure=object()
        explicit, circles, edges = set(), set(), Counter()
        declared=defaultdict(set);support=Counter()
        for row in self.parsed.values():
            display, folder = row[2:]
            observed=set()
            for credit in (display, folder):
                explicit.update(name_key(n) for n in credit.artists)
                if credit.circle: circles.add(name_key(credit.circle))
                for primary,alternate in credit.aliases:
                    primary,alternate=name_key(primary),name_key(alternate)
                    if primary!=alternate:
                        declared[alternate].add(primary);observed.add((primary,alternate))
            support.update(observed)
        for row in self.parsed.values():
            display,folder=row[2:]
            def single(credit):
                if len(credit.artists)==1:return credit.artists[0]
                if credit.untyped and (name_key(credit.untyped) not in circles or name_key(credit.untyped) in explicit):return credit.untyped
                return None
            a,b=single(display),single(folder)
            if a and b and name_key(a)!=name_key(b) and east_asian(a)!=east_asian(b):
                edges[tuple(sorted((name_key(a),name_key(b))))]+=1
        peers = defaultdict(set)
        for a,b in edges: peers[a].add(b);peers[b].add(a)
        targets=defaultdict(set)
        # One same-book bilingual credit suffices. A Japanese name may have
        # multiple romanizations. A roman name pointing at two distinct Japanese
        # names is ambiguous and is never a bridge joining those people.
        for a,b in edges:
            japanese,roman=(a,b) if east_asian(a) else (b,a)
            targets[roman].add(japanese)
            support[(japanese,roman)]+=edges[(a,b)]
        for alternate,primaries in declared.items():targets[alternate].update(primaries)
        proposed={n:next(iter(values)) for n,values in targets.items() if len(values)==1}
        # An explicit alias can point directly to a primary, never through an
        # alias chain. Conflicts and cycles remain separate, regardless of votes.
        aliases={n:target for n,target in proposed.items() if target not in proposed and len(targets.get(target,()))<=1}
        self.alias_support={n:support[(target,n)] for n,target in aliases.items()}
        self.alias_pairs = sum(1 for n,target in aliases.items() if n!=target)
        self.ambiguous_names = {n for n,p in targets.items() if len(p)>1} | (set(proposed)-set(aliases))
        identities={};canonical_names={};choice_records={};creator_records={}
        def identity_for(exact):
            if exact not in identities:identities[exact]=author_id(exact)
            return identities[exact]
        def canonical_for(exact):
            value=aliases.get(exact,exact)
            return canonical_names.setdefault(value,value)
        spellings=defaultdict(set)
        self.group_for={};self.group_loose=defaultdict(set);self.loose_groups=defaultdict(set)
        for row in self.parsed.values():
            for credit in row[2:]:
                names=(credit.artists or ((credit.untyped,) if credit.untyped else ()))+tuple(n for pair in credit.aliases for n in pair)
                for name in names:
                    exact=name_key(name);group=canonical_for(exact);identity=identity_for(exact)
                    self.group_for[identity]=group
                    spellings[group].add(name)
                    # Conflicting bilingual names remain isolated; weak matches
                    # are one-hop layout candidates, never transitive aliases.
                    if exact not in self.ambiguous_names:
                        for variant in variant_keys(name):
                            self.group_loose[group].add(variant);self.loose_groups[variant].add(group)
        groups = defaultdict(list)
        self.choices={};self.creators={};self.kinds={}
        self.cost = 1024
        for book in books:
            display,folder = self.parsed[book['id']][2:]
            # A display title can omit its creator while the saved download
            # folder still contains an explicit artist credit. Prefer explicit
            # roles over an ambiguous standalone circle, never over another
            # explicit display artist (including multi-artist collaboration).
            credit = display if display.artists else folder if folder.artists else display
            if not credit.untyped and not credit.artists:credit=folder
            names = credit.artists
            kind = 'artist'
            if not names and credit.untyped:
                name = name_key(credit.untyped)
                # A known circle is not silently promoted to artist. Explicit
                # artist evidence with the same spelling remains usable.
                if name not in circles or name in explicit:
                    names = (credit.untyped,)
                    kind = 'artist' if name in explicit else 'name'
            choices = [];book_groups=[]
            for name in names:
                exact=name_key(name);canonical=canonical_for(exact);identity=identity_for(exact)
                if canonical in book_groups: continue
                choices.append(identity);book_groups.append(canonical);groups[canonical].append(book['id'])
                self.kinds[(book['id'],canonical)]='name' if exact in self.ambiguous_names else kind
            choices=tuple(choices);book_groups=tuple(book_groups)
            self.choices[book['id']]=choice_records.setdefault(choices,choices)
            self.creators[book['id']]=creator_records.setdefault(book_groups,book_groups)
            self.cost += 256 + 2*(len(book['title'].encode())+len(book['directory'].encode())) + len(choices)*128
            if self.cost > self.budget: raise ValueError('author_index_limit')
        self.group_members={g:tuple(ids) for g,ids in groups.items()}
        # Circle-only entries are display candidates only. Two distinct books
        # must independently credit the same sole artist; collaborations and
        # competing display/folder evidence disable the inference.
        circle_artists=defaultdict(set);circle_books=defaultdict(set)
        for gid,row in self.parsed.items():
            for credit in row[2:]:
                if credit.circle:
                    circle=name_key(credit.circle)
                    circle_books[circle].add(gid)
                    circle_artists[circle].update(canonical_for(name_key(n)) for n in credit.artists)
        owners={c:next(iter(names)) for c,names in circle_artists.items() if len(names)==1 and len(circle_books[c])>=2}
        candidates=defaultdict(list);self.candidate_choices={};self.candidate_group_for={}
        for gid,row in self.parsed.items():
            if self.creators[gid]:continue
            credits=row[2:]
            names={name_key(c.untyped) for c in credits if c.untyped}
            if len(names)!=1:continue
            circle=next(iter(names));owner=owners.get(circle)
            if owner not in self.group_members:continue
            selector=author_id('circle\n'+circle)
            self.candidate_choices[gid]=(selector,);self.candidate_group_for[selector]=owner
            candidates[owner].append(gid)
        self.candidate_members={g:tuple(ids) for g,ids in candidates.items()}
        # Failed credits can mention a known complete name. Keep such books out
        # of creators/aliases/series and expose them only to opted-in clients.
        known={}
        for group,names in spellings.items():
            if group not in self.group_members:continue
            for name in names:
                exact=name_key(name)
                if exact not in circles and exact not in self.ambiguous_names:known[exact]=group
        weak=defaultdict(list);self.known_choices={};self.known_group_for={}
        for gid,row in self.parsed.items():
            if self.creators[gid] or any(c!=Credit() for c in row[2:]):continue
            hits=[{n:known[n] for n in tokens if n in known} for tokens in self.fallback_tokens[gid]]
            if all(hits) and set(hits[0].values())!=set(hits[1].values()):continue
            matches=hits[0] or hits[1]
            groups_seen=set();choices=[];selectors={}
            for name,group in matches.items():
                if group in groups_seen:continue
                groups_seen.add(group)
                selector=author_id('credit\n'+name)
                choices.append(selector);selectors[selector]=group
            if not 1<=len(choices)<=8:continue
            self.known_group_for.update(selectors)
            self.known_choices[gid]=tuple(choices)
            for group in groups_seen:weak[group].append(gid)
        self.known_members={g:tuple(ids) for g,ids in weak.items()}
        # Deterministic bounded presentation, independent of download order.
        self.spellings={g:tuple(sorted(names,key=lambda n:(not east_asian(n),name_key(n),n))[:8]) for g,names in spellings.items()}
        self.labels={g:names[0] for g,names in self.spellings.items()}
        self.members={i:self.group_members[g] for i,g in self.group_for.items() if g in self.group_members}
        self.cost += sum(512+2*len(n.encode()) for n in self.group_for.values())
        self.cost += sum(192+2*len(n.encode()) for names in spellings.values() for n in names)
        self.cost += sum(128+len(groups)*64 for groups in self.loose_groups.values())
        self.cost += sum(128+len(ids)*64 for ids in self.candidate_members.values())+len(self.candidate_choices)*160
        self.cost += sum(128+2*len(n.encode()) for n in self.alias_support)
        self.cost += len(self.fallback_tokens)*40+sum(64+2*len(n.encode()) for sources in self.fallback_tokens.values() for tokens in sources for n in tokens)
        self.cost += sum(128+len(ids)*64 for ids in self.known_members.values())+sum(160+len(ids)*128 for ids in self.known_choices.values())
        if self.cost > self.budget: raise ValueError('author_index_limit')

    def nearby_groups(self,group):
        """Direct spelling evidence only; never walk peers of a peer."""
        peers=set()
        for loose in self.group_loose.get(group,()):
            if len(self.loose_groups[loose])>33:return ()
            peers.update(self.loose_groups[loose])
            if len(peers)>33:return ()
        peers.discard(group)
        return tuple(sorted(peers)) if len(peers)<=32 else ()

    def selector_group(self,identity):
        return self.group_for.get(identity,self.candidate_group_for.get(identity,self.known_group_for.get(identity)))

    def _matches(self, group, include_possible, expanded=False, known=False, work_peers=None):
        strong=self.group_members[group]
        if not include_possible:return strong,frozenset()
        candidates=set()
        for loose in self.group_loose.get(group,()):
            for other in self.loose_groups[loose]:
                if other!=group:candidates.update(self.group_members.get(other,()))
        if expanded:candidates.update(self.candidate_members.get(group,()))
        if expanded and known:candidates.update(self.known_members.get(group,()))
        if expanded and work_peers:
            for peer in work_peers.get(group,()):candidates.update(self.group_members.get(peer,()))
        candidates.difference_update(strong)
        if not candidates:return strong,frozenset()
        return tuple(sorted(set(strong)|candidates,key=self.order.__getitem__)),frozenset(candidates)

    def details(self, gid, identity, include_possible=False, expanded=False, known=False, work_peers=None):
        candidate=expanded and identity in self.candidate_choices.get(gid,())
        inferred=expanded and known and identity in self.known_choices.get(gid,())
        group=self.known_group_for.get(identity) if inferred else self.candidate_group_for.get(identity) if candidate else self.group_for.get(identity)
        candidate=candidate or inferred
        if not candidate and group not in self.creators.get(gid,()):raise KeyError(identity)
        ids,possible=self._matches(group,include_possible or expanded,expanded,known,work_peers)
        option=dict(id=identity,name=self.labels[group],matchKind='name' if candidate else self.kinds[(gid,group)],count=len(ids),
                    aliases=list(self.spellings[group][1:]))
        if include_possible or expanded:option['possibleCount']=len(possible)
        if expanded:option['evidenceVersion']=3
        return option,ids,possible

    def notes(self,group,possible,work_peers=None):
        circles=set(self.candidate_members.get(group,()))
        known=set(self.known_members.get(group,()))
        work={gid for peer in (work_peers or {}).get(group,()) for gid in self.group_members.get(peer,())}
        return {gid:'creditName' if gid in known else 'circle' if gid in circles else 'workCredit' if gid in work else 'nameVariant' for gid in possible}

    def options(self, gid, include_possible=False, expanded=False, known=False, work_peers=None):
        choices=self.choices.get(gid,())+(self.candidate_choices.get(gid,()) if expanded else ())
        if expanded and known:choices+=self.known_choices.get(gid,())
        return [self.details(gid,i,include_possible,expanded,known,work_peers)[0] for i in choices]

    def selection(self, gid, identity):
        option,ids,_=self.details(gid,identity)
        return option,ids
