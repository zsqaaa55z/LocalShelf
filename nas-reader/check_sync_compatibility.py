"""Exercise the real sync Store with temporary data, not a hand-built schema.
Usage: python check_sync_compatibility.py /path/to/LocalShelfSync/receiver/server.py
"""
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
from server import Identity, Reader, Failure


def main():
    spec=importlib.util.spec_from_file_location('localshelf_sync_compat',sys.argv[1])
    sync=importlib.util.module_from_spec(spec);spec.loader.exec_module(sync)
    with tempfile.TemporaryDirectory() as directory:
        root=Path(directory)
        store=sync.Store(root/'source',reserve_bytes=0,reserve_percent=0,warning_bytes=0,warning_percent=0)
        reader=Reader(root/'source',Identity(root/'reader-state'))
        books=[{'id':'2','rank':0,'title':'Synthetic newest','directory':'2-test','time':20},
               {'id':'1','rank':1,'title':'Synthetic missing','directory':'1-test','time':10}]
        cat={'schema':1,'orderSource':'ehviewer-downloads-time-desc','orderVerified':True,'books':books,'retentionPolicy':'keep-omitted-files-v1'}
        revision=store.stage(cat)['revision']
        try:
            reader.list(0,50);raise AssertionError('staged catalog exposed')
        except Failure as error:assert error.status==503
        print('PASS real receiver staged catalog stays private')
        data=b'GIF89a temporary fixture'
        file={'path':'00000003.gif','size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        begin=store.begin(dict(file,revision=revision,gid='2'))
        store.chunk(begin['upload'],0,data);store.finish(begin['upload'])
        store.book_commit({'revision':revision,'gid':'2','files':[file]})
        store.book_commit({'revision':revision,'gid':'1','files':[]})
        store.publish({'revision':revision})
        before=list(store.db.iterdump())
        result=reader.list(0,50)
        assert result['catalogRevision']==revision and [b['id'] for b in result['books']]==['2','1']
        assert result['books'][0]['available'] and not result['books'][1]['available']
        assert result['books'][0]['pageCount']==1 and result['books'][1]['pageCount'] is None
        print('PASS real receiver publication preserves exact order and missing slot')
        assert reader.pages('2')=={'pages':[{'number':3}]}
        image,_,_=reader.image('2',3)
        with image:assert image.read()==data
        print('PASS real receiver file inventory maps to original numeric GIF page')
        assert before==list(store.db.iterdump())
        print('PASS reading does not mutate real receiver tables')
        first=reader.manifest_response('2')
        assert reader.manifest_response('2') is first and reader.manifest_stats['hits']==1
        assert first[1]=='"'+hashlib.sha256(first[0]).hexdigest()+'"'
        print('PASS real committed receipt permits immutable manifest reuse')
        added=b'JPEG synthetic next page'
        next_file={'path':'00000004.jpg','size':len(added),'sha256':hashlib.sha256(added).hexdigest()}
        begin=store.begin(dict(next_file,revision=revision,gid='2'))
        store.chunk(begin['upload'],0,added);store.finish(begin['upload'])
        assert reader.pages('2')=={'pages':[{'number':3},{'number':4}]}
        assert reader.list(0,50)['catalogRevision']==revision
        assert reader.list(0,50)['books'][0]['pageCount']==2
        print('PASS real receiver same-revision file commit invalidates cached pages')
        added_manifest=reader.manifest_response('2')
        assert added_manifest[1]!=first[1]
        assert store.db.execute("SELECT proof FROM book_versions WHERE gid='2'").fetchone() is None
        print('PASS real file finish revokes receipt before changed manifest reuse')
        thumb=b'JPEG synthetic small cover'
        thumb_file={'path':'.thumb','size':len(thumb),'sha256':hashlib.sha256(thumb).hexdigest()}
        begin=store.begin(dict(thumb_file,revision=revision,gid='2'))
        store.chunk(begin['upload'],0,thumb);store.finish(begin['upload'])
        image,_,sha=reader.image('2')
        with image:assert image.read()==thumb
        assert reader.list(0,50)['books'][0]['coverIdentity']==sha
        print('PASS real receiver added thumbnail refreshes batch cover identity')
        store.book_commit({'revision':revision,'gid':'2','files':[file,next_file,thumb_file]})
        before=list(store.db.iterdump())
        reader.pages('2');reader.list(0,50)
        assert before==list(store.db.iterdump())
        print('PASS cached reading still leaves all receiver tables unchanged')
        complete=reader.manifest_response('2')
        assert reader.manifest_response('2') is complete
        print('PASS completed incremental inventory restores safe response caching')
        alternate=b'WEBP synthetic same numeric page'
        alternate_file={'path':'00000004.webp','size':len(alternate),'sha256':hashlib.sha256(alternate).hexdigest()}
        begin=store.begin(dict(alternate_file,revision=revision,gid='2'))
        store.chunk(begin['upload'],0,alternate);store.finish(begin['upload'])
        store.book_commit({'revision':revision,'gid':'2','files':[file,next_file,thumb_file,alternate_file]})
        before=list(store.db.iterdump())
        assert reader.pages('2')=={'pages':[{'number':3},{'number':4}]}
        image,_,sha=reader.image('2',4)
        with image:assert image.read()==added
        assert sha==next_file['sha256'] and before==list(store.db.iterdump())
        assert reader.list(0,50)['books'][0]['pageCount']==2
        assert (root/'source'/'books'/'2-test'/'00000004.webp').read_bytes()==alternate
        print('PASS real receiver duplicate formats remain intact; reader selects JPG once')
        assert reader.manifest_response('2')[1]==complete[1]
        print('PASS extra nonselected format does not invalidate selected page response')
        reordered=[{**books[1],'rank':0,'time':30},{**books[0],'rank':1,'time':20}]
        next_revision=store.stage({**cat,'books':reordered})['revision']
        store.book_commit({'revision':next_revision,'gid':'1','files':[]})
        store.book_commit({'revision':next_revision,'gid':'2','files':[file,next_file,thumb_file,alternate_file]})
        store.publish({'revision':next_revision})
        before=list(store.db.iterdump())
        assert reader.locate('2')['offset']==1 and reader.manifest_response('2')[1]==complete[1]
        assert reader.list(0,50)['books'][1]['pageCount']==2
        assert before==list(store.db.iterdump())
        print('PASS real reorder changes book position but retains manifest identity')
        store.close()
        # SQLite may checkpoint/remove WAL on clean close. A read-only opener must
        # still work without immutable mode; Docker RO mount itself needs NAS QA.
        assert reader.list(0,50)['total']==2
        print('PASS reader sees committed library after clean receiver shutdown')
        reader.close()
    print('14 real receiver compatibility checks passed')


if __name__=='__main__':main()
