"""Private, bounded, authenticated metadata snapshots; never pickle or media.

One disposable snapshot plus one atomic-write temporary file, each <= 32 MiB.
Only explicit built-in types and the two naming records can be reconstructed.
An index remains immutable after publication. Its shared tuples are retained by
the node table instead of expanding a large group's members once per selector.
"""
import hashlib
import hmac
import fcntl
import json
import os
import re
from pathlib import Path
import stat
import tempfile
import threading
from collections import defaultdict

from authors import AuthorIndex, Credit
from series import SeriesIndex, ParsedSeries

AUTHOR_FIELDS = ('parsed','choices','labels','kinds','spellings','group_for','creators',
    'group_loose','loose_groups','alias_pairs','ambiguous_names','cost','candidate_members',
    'candidate_choices','candidate_group_for','alias_support','group_members',
    'fallback_tokens','known_members','known_choices','known_group_for')
SERIES_FIELDS = ('parsed','choices','group_for','labels','part_labels','aliases','cost',
    'expanded_choices','expanded_group_for','expanded_labels','expanded_aliases',
    'group_notes','group_members','expanded_members','relaxed')
MAX_BYTES = 32*1024*1024
MAX_NODES = 400000
MAX_EDGES = 2000000


def rules_version():
    digest=hashlib.sha256()
    for name in ('authors.py','series.py','relaxed.py','related_cache.py'):
        digest.update(Path(__file__).with_name(name).read_bytes())
    return digest.hexdigest()


def metadata_version(books):
    digest=hashlib.sha256()
    for b in sorted(books,key=lambda b:b['id']):
        digest.update(json.dumps([b['id'],b['title'],b['directory']],ensure_ascii=False,separators=(',',':')).encode())
        digest.update(b'\n')
    return digest.hexdigest()


def pack_graph(value):
    nodes=[];seen={};edges=0
    def add(v,depth=0):
        nonlocal edges
        if depth>16:raise ValueError('snapshot_depth')
        if id(v) in seen:return seen[id(v)]
        t=type(v)
        if t is str:tag,data='s',v
        elif t is int:tag,data='i',v
        elif v is None:tag,data='n',None
        elif t in (dict,defaultdict,tuple,list,set,frozenset) or t in (Credit,ParsedSeries):
            if t in (dict,defaultdict):tag='d';data=[[add(k,depth+1),add(x,depth+1)] for k,x in v.items()];edges+=2*len(data)
            else:
                if t is Credit:tag='c';values=(v.artists,v.circle,v.untyped,v.aliases)
                elif t is ParsedSeries:tag='p';values=(v.root,v.part,v.subtitle,v.edition,v.candidate_root)
                else:tag={tuple:'t',list:'l',set:'e',frozenset:'f'}[t];values=v
                data=[add(x,depth+1) for x in values];edges+=len(data)
        else:raise ValueError('snapshot_type')
        if len(nodes)>=MAX_NODES or edges>MAX_EDGES:raise ValueError('snapshot_limit')
        index=len(nodes);nodes.append([tag,data]);seen[id(v)]=index;return index
    root=add(value)
    return [nodes,root]


def unpack_graph(graph):
    if not isinstance(graph,list) or len(graph)!=2:raise ValueError('snapshot_graph')
    nodes,root=graph
    if not isinstance(nodes,list) or not 0<len(nodes)<=MAX_NODES or type(root) is not int or root!=len(nodes)-1:raise ValueError('snapshot_nodes')
    values=[];depths=[];edges=0
    for index,node in enumerate(nodes):
        if not isinstance(node,list) or len(node)!=2:raise ValueError('snapshot_node')
        tag,data=node;depth=0
        if tag=='s':
            if not isinstance(data,str) or len(data.encode())>32768:raise ValueError('snapshot_string')
            value=data
        elif tag=='i':
            if type(data) is not int or not 0<=data<=MAX_BYTES:raise ValueError('snapshot_integer')
            value=data
        elif tag=='n' and data is None:value=None
        else:
            if tag not in ('d','t','l','e','f','c','p') or not isinstance(data,list):raise ValueError('snapshot_type')
            refs=[]
            for item in data:
                if tag=='d':
                    if not isinstance(item,list) or len(item)!=2:raise ValueError('snapshot_pair')
                    refs.extend(item)
                else:refs.append(item)
            edges+=len(refs)
            if edges>MAX_EDGES or any(type(n) is not int or not 0<=n<index for n in refs):raise ValueError('snapshot_reference')
            depth=1+max((depths[n] for n in refs),default=0)
            if depth>16:raise ValueError('snapshot_depth')
            items=[values[n] for n in refs]
            if tag=='d':
                value=dict(zip(items[::2],items[1::2]))
                if len(value)!=len(data):raise ValueError('snapshot_duplicate_key')
            elif tag=='t':value=tuple(items)
            elif tag=='l':value=items
            elif tag=='e':value=set(items)
            elif tag=='f':value=frozenset(items)
            elif tag=='c':
                if len(items)!=4 or not isinstance(items[0],tuple) or not all(isinstance(s,str) for s in items[0]) or not all(isinstance(items[n],str) for n in (1,2)) or not isinstance(items[3],tuple):raise ValueError('snapshot_credit')
                value=Credit(*items)
            else:
                if len(items)!=5 or not all(isinstance(s,str) for s in items):raise ValueError('snapshot_series')
                value=ParsedSeries(*items)
        values.append(value);depths.append(depth)
    return values[root]


class RelatedDiskCache:
    def __init__(self,state,scope,token):
        self.root=Path(state);self.path=self.root/'related-index-v1.cache'
        self.scope=scope;self.rules=rules_version()
        self.key=hashlib.sha256(('localshelf-related-cache-v1\n'+token).encode()).digest()
        self.restores=0;self.saves=0;self.misses=0
        self.saved_metadata=None

    def load(self,books):
        try:
            if self.root.is_symlink():raise ValueError('snapshot_path')
            fd=os.open(self.path,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'rb') as stream:
                info=os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or not 33<info.st_size<=MAX_BYTES:raise ValueError('snapshot_size')
                signature=stream.read(32);payload=stream.read(MAX_BYTES)
            # Verify BEFORE parsing. This binds state to the existing private
            # reader identity without storing credentials in the cache file.
            if not hmac.compare_digest(signature,hmac.digest(self.key,payload,'sha256')):raise ValueError('snapshot_integrity')
            record=json.loads(payload)
            if not isinstance(record,dict) or record.keys()!= {'schema','scope','rules','metadata','graph'} or record['schema']!=1 or record['scope']!=self.scope or record['rules']!=self.rules or record['metadata']!=metadata_version(books):raise ValueError('snapshot_stale')
            graph=unpack_graph(record['graph'])
            if not isinstance(graph,dict) or graph.keys()!={'author','series'}:raise ValueError('snapshot_index')
            a,s=graph['author'],graph['series']
            if not isinstance(a,dict) or set(a)!=set(AUTHOR_FIELDS) or not isinstance(s,dict) or set(s)!=set(SERIES_FIELDS):raise ValueError('snapshot_fields')
            for fields,limit in ((a,AuthorIndex.budget),(s,SeriesIndex.budget)):
                if type(fields['cost']) is not int or fields['cost']>limit or set(fields['parsed'])!={b['id'] for b in books}:raise ValueError('snapshot_budget')
                for b in books:
                    if fields['parsed'][b['id']][:2]!=(b['title'],b['directory']):raise ValueError('snapshot_metadata')
            author=AuthorIndex.__new__(AuthorIndex);series=SeriesIndex.__new__(SeriesIndex)
            for name,value in a.items():setattr(author,name,value)
            for name,value in s.items():setattr(series,name,value)
            author.structure=object();series.authors_structure=author.structure
            # Reuse the existing incremental path to apply the CURRENT order.
            author=AuthorIndex(books,author);series=SeriesIndex(books,author,series)
            self.saved_metadata=record['metadata'];self.restores+=1;return author,series
        except (OSError,ValueError,TypeError,KeyError,AttributeError,IndexError,RecursionError):
            self.misses+=1;return None

    def save(self,books,author,series):
        temporary=None
        try:
            if self.root.is_symlink():raise ValueError('snapshot_path')
            metadata=metadata_version(books)
            if metadata==self.saved_metadata:return True
            graph=pack_graph({'author':{k:getattr(author,k) for k in AUTHOR_FIELDS},'series':{k:getattr(series,k) for k in SERIES_FIELDS}})
            payload=json.dumps(dict(schema=1,scope=self.scope,rules=self.rules,metadata=metadata,graph=graph),ensure_ascii=False,separators=(',',':')).encode()
            if len(payload)+32>MAX_BYTES:raise ValueError('snapshot_size')
            fd=os.open(self.root/'.related-index-v1.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'rb') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                # A previous crash may have left one partial. Another process
                # cannot be actively writing these files while this lock is held.
                for path in self.root.glob('.related-index-*'):
                    if re.fullmatch(r'\.related-index-[a-z0-9_]{8}',path.name):path.unlink()
                fd,temporary=tempfile.mkstemp(prefix='.related-index-',dir=self.root)
                with os.fdopen(fd,'wb') as stream:
                    stream.write(hmac.digest(self.key,payload,'sha256'));stream.write(payload);stream.flush();os.fsync(stream.fileno())
                os.replace(temporary,self.path);temporary=None
            self.saved_metadata=metadata;self.saves+=1;return True
        except (OSError,ValueError,TypeError,KeyError,RecursionError):return False
        finally:
            if temporary is not None:
                try:os.unlink(temporary)
                except OSError:pass


class RelatedWarmup:
    """One optional idle worker, never a source write or a media scan."""
    def __init__(self,reader,idle):
        self.reader,self.idle=reader,idle;self.stop_event=threading.Event();self.thread=None
        self.last_books=None;self.errors=0

    def tick(self):
        if self.stop_event.is_set() or not self.idle():return
        with self.reader.connection() as db:
            _,books,_=self.reader.snapshot(db)
        if books is self.last_books:return
        if self.stop_event.is_set() or not self.idle():return
        # All parsing and disk IO happen AFTER releasing the SQLite read txn.
        author,series=self.reader.related_indexes(books,True)
        if self.stop_event.is_set() or not self.idle():return
        with self.reader.connection() as db:
            _,current,_=self.reader.snapshot(db)
        if current is not books:return
        self.reader.related_disk.save(books,author,series)
        self.last_books=books

    def run(self):
        while not self.stop_event.wait(2):
            try:self.tick()
            except Exception:self.errors+=1

    def start(self):
        self.thread=threading.Thread(target=self.run,name='related-warmup',daemon=True);self.thread.start()

    def close(self):
        self.stop_event.set()
        if self.thread is not None:self.thread.join(timeout=10)
