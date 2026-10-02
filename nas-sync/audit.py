"""Read-only, streaming receiver audit. Pause writers before running this tool."""
import argparse, hashlib, json, sqlite3, stat
from pathlib import Path
from server import validate_catalog, relative, component, archive_id

def check_file(root, path, size, sha, rehash):
    cur=root
    for piece in path.relative_to(root).parts:
        cur=cur/piece
        if cur.is_symlink():raise ValueError('symlink_not_allowed')
    before=path.stat()
    if not stat.S_ISREG(before.st_mode) or before.st_size!=size:raise ValueError('file_size_mismatch')
    if rehash:
        h=hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda:stream.read(4*1024*1024),b''):h.update(chunk)
        after=path.stat()
        if (before.st_size,before.st_mtime_ns,before.st_ino)!=(after.st_size,after.st_mtime_ns,after.st_ino):raise ValueError('file_changed_during_audit')
        if h.hexdigest()!=sha:raise ValueError('hash_mismatch')

def audit_archive(root, revision, source_revision, wanted, rehash, issue):
    base=root/'archive'
    if base.is_symlink():raise ValueError('symlink_not_allowed')
    db=sqlite3.connect((base/'index.sqlite3').as_uri()+'?mode=ro',uri=True)
    count=size=0
    try:
        db.execute('BEGIN')
        if [r[0] for r in db.execute('PRAGMA integrity_check')]!=['ok']:issue('archive_sqlite_integrity_failed')
        row=db.execute('SELECT body FROM catalogs WHERE revision=?',(revision,)).fetchone()
        if not row:raise ValueError('archive_not_found')
        cat=json.loads(row[0])
        if cat.get('type')!='localshelf-extra-v1' or cat.get('sourceRevision')!=source_revision:raise ValueError('archive_source_revision_mismatch')
        groups=cat['groups'];ids=[g['id'] for g in groups]
        if len(set(ids))!=len(ids) or set(ids)!=set(wanted):issue('archive_source_groups_mismatch')
        ready={r[0] for r in db.execute('SELECT gid FROM ready WHERE revision=?',(revision,))}
        if ready!=set(ids):issue('archive_groups_not_committed')
        for group in groups:
            kind,name=group['kind'],group['name'];gid=group['id']
            if kind=='directory':component(name);directory='directories/'+name
            elif kind=='root' and name=='':directory='root-files'
            else:raise ValueError('invalid_archive_group')
            if gid!=archive_id(kind,name):raise ValueError('invalid_archive_id')
            row=db.execute('SELECT body FROM inventories WHERE revision=? AND gid=?',(revision,gid)).fetchone()
            if not row:issue('archive_inventory_missing',gid=gid);continue
            files=json.loads(row[0]);seen=set();group_bytes=0
            for f in files:
                relative(f['path']);path=base/'books'/directory/f['path']
                if f['path'] in seen:issue('archive_duplicate_file',gid=gid)
                seen.add(f['path']);group_bytes+=f['size']
                try:check_file(root,path,f['size'],f['sha256'],rehash);count+=1;size+=f['size']
                except (OSError,ValueError) as e:issue('archive_'+(type(e).__name__ if isinstance(e,OSError) else str(e)),gid=gid,path=f['path'])
            if gid not in wanted or wanted[gid]!={'files':len(files),'bytes':group_bytes}:issue('archive_source_totals_mismatch',gid=gid)
        return count,size
    finally:db.close()

def audit(root, expected, baseline=None, rehash=True, revision=None):
    root=Path(root).resolve()
    validate_catalog(expected)
    db=sqlite3.connect((root/'index.sqlite3').as_uri()+'?mode=ro',uri=True)
    db.row_factory=sqlite3.Row
    issues=[]; issue_count=0
    def issue(code, **detail):
        nonlocal issue_count
        issue_count+=1
        if len(issues)<100:issues.append({'code':code,**detail})
    counts={b['id']:{'files':0,'bytes':0} for b in expected['books']}
    expected_dirs={b['id']:b['directory'] for b in expected['books']}
    checked=checked_bytes=0
    try:
        db.execute('BEGIN')
        integrity=[r[0] for r in db.execute('PRAGMA integrity_check')]
        if integrity!=['ok']:issue('sqlite_integrity_failed')
        active=db.execute("SELECT value FROM state WHERE key='active'").fetchone()
        active=active[0] if active else None
        target=revision or active
        row=db.execute('SELECT body FROM catalogs WHERE revision=?',(target,)).fetchone() if target else None
        order_ok=False
        if row:
            cat=json.loads(row[0]);validate_catalog(cat)
            fields=lambda b:(b['id'],b['directory'],b['time'],b['rank'])
            order_ok=[fields(b) for b in cat['books']]==[fields(b) for b in expected['books']]
            if not order_ok:issue('order_or_directory_mismatch')
        else:issue('catalog_not_found')
        ready={r[0] for r in db.execute('SELECT gid FROM ready WHERE revision=?',(target,))}
        pending=len(set(counts)-ready)
        if pending:issue('books_not_committed',count=pending)
        for r in db.execute('SELECT gid,directory,path,size,sha FROM files'):
            if r['gid'] not in counts:continue
            gid=r['gid'];counts[gid]['files']+=1;counts[gid]['bytes']+=r['size']
            try:
                component(r['directory']);relative(r['path'])
                if r['directory']!=expected_dirs[gid]:raise ValueError('directory_mismatch')
                path=root/'books'/r['directory']/r['path']
                cur=root
                for piece in path.relative_to(root).parts:
                    cur=cur/piece
                    if cur.is_symlink():raise ValueError('symlink_not_allowed')
                before=path.stat()
                if not stat.S_ISREG(before.st_mode) or before.st_size!=r['size']:raise ValueError('file_size_mismatch')
                if rehash:
                    h=hashlib.sha256()
                    with path.open('rb') as stream:
                        for chunk in iter(lambda:stream.read(4*1024*1024),b''):h.update(chunk)
                    after=path.stat()
                    if (before.st_size,before.st_mtime_ns,before.st_ino)!=(after.st_size,after.st_mtime_ns,after.st_ino):raise ValueError('file_changed_during_audit')
                    if h.hexdigest()!=r['sha']:raise ValueError('hash_mismatch')
                checked+=1;checked_bytes+=r['size']
            except (OSError,ValueError) as e:issue(type(e).__name__ if isinstance(e,OSError) else str(e),gid=gid,path=r['path'])
        source_ok=False;archive_count=archive_bytes=0
        if baseline is not None:
            if set(baseline['books'])!=set(counts):issue('source_catalog_ids_mismatch')
            for gid,wanted in baseline['books'].items():
                if gid not in counts or counts[gid]!={'files':wanted['files'],'bytes':wanted['bytes']}:
                    issue('source_totals_mismatch',gid=gid)
            if 'archives' in baseline:
                link=db.execute("SELECT value FROM state WHERE key='active_archive'").fetchone()
                if not link or target!=active:issue('archive_not_linked_to_active_catalog')
                else:
                    try:archive_count,archive_bytes=audit_archive(root,link[0],target,baseline['archives'],rehash,issue)
                    except (OSError,ValueError,sqlite3.Error) as e:issue('archive_audit_failed',reason=str(e))
                if 'totalSourceFiles' in baseline and checked+archive_count!=baseline['totalSourceFiles']:issue('combined_source_file_count_mismatch')
                if 'totalSourceBytes' in baseline and checked_bytes+archive_bytes!=baseline['totalSourceBytes']:issue('combined_source_bytes_mismatch')
            elif baseline.get('unmappedDirectoryCount',0) or baseline.get('rootFileCount',0):
                issue('source_files_outside_catalog',directories=baseline.get('unmappedDirectoryCount',0),rootFiles=baseline.get('rootFileCount',0))
            if baseline.get('missingDirectoryCount',0):issue('source_directories_missing',count=baseline['missingDirectoryCount'])
            if baseline.get('missingOrEmptyDirectoryCount',0):issue('source_directories_empty_or_missing',count=baseline['missingOrEmptyDirectoryCount'])
            source_ok=issue_count==0
        return {'scope':'stored ledger and explicitly supplied source baseline; pause writers before audit',
                'revision':target,'activeRevision':active,'orderMatches':order_ok,'pendingBooks':pending,
                'registeredFiles':sum(v['files'] for v in counts.values()),'checkedFiles':checked,'checkedBytes':checked_bytes,
                'archiveCheckedFiles':archive_count,'archiveCheckedBytes':archive_bytes,'combinedCheckedFiles':checked+archive_count,'combinedCheckedBytes':checked_bytes+archive_bytes,
                'sha256Rehashed':rehash,'sourceBaselineSupplied':baseline is not None,'issueCount':issue_count,'issues':issues,
                'receiverChecksPassed':issue_count==0,
                'fullLibraryAccepted':bool(issue_count==0 and rehash and source_ok and target==active)}
    finally:db.close()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data',required=True);p.add_argument('--expected',required=True)
    p.add_argument('--baseline');p.add_argument('--revision');p.add_argument('--quick',action='store_true',help='Skip content hashing; never grants full acceptance')
    a=p.parse_args()
    result=audit(a.data,json.loads(Path(a.expected).read_text()),json.loads(Path(a.baseline).read_text()) if a.baseline else None,not a.quick,a.revision)
    print(json.dumps(result,ensure_ascii=False,indent=2))
    raise SystemExit(0 if result['fullLibraryAccepted'] else 2)

if __name__=='__main__':main()
