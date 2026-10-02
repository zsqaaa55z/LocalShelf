"""Isolated QA server. Uses the existing NAS implementation with generated test images.
Never opens the user's NAS, manga, credentials or source database.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
from PIL import Image, ImageDraw

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT.parent / 'nas-reader'))
from server import Identity, Reader, Server
from manual import ManualStore, POLICY
from thumbnails import ThumbnailCache


def frame(index, size=(720, 1000), label='LocalShelf'):
    image = Image.new('RGB', size, (18 + index * 5 % 70, 38, 55 + index * 9 % 100))
    draw = ImageDraw.Draw(image)
    w, h = size
    draw.rounded_rectangle((w * .12, h * .17, w * .88, h * .82), radius=35, outline=(97, 200, 183), width=10)
    draw.ellipse((w*.2+index*8%180,h*.35,w*.5+index*8%180,h*.55),fill=(97,200,183))
    draw.text((w*.18,h*.24),label,fill='white',font_size=max(24,w//15))
    draw.text((w*.18,h*.68),f'FRAME {index+1:02}',fill='white',font_size=max(24,w//18))
    return image


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8098);parser.add_argument('--books',type=int,default=10073);args=parser.parse_args()
    root=Path(tempfile.mkdtemp(prefix='android-reader-fixture-'))
    source=root/'source';source.mkdir();assets=root/'assets';assets.mkdir()
    frame(0,label='STATIC / 01').save(assets/'00000001.jpg',quality=90)
    frames=[frame(i,label='ANIMATED / GIF') for i in range(16)]
    frames[0].save(assets/'00000002.gif',save_all=True,append_images=frames[1:],duration=70,loop=0)
    frames=[frame(i,label='ANIMATED / WEBP') for i in range(16)]
    frames[0].save(assets/'00000003.webp',save_all=True,append_images=frames[1:],duration=70,loop=0,quality=80)
    frame(4,(2400,3600),label='LARGE STATIC').save(assets/'00000004.jpg',quality=90)
    frames=[frame(i,(1800,2400),label='LARGE ANIMATION') for i in range(8)]
    frames[0].save(assets/'00000005.webp',save_all=True,append_images=frames[1:],duration=90,loop=0,quality=80)
    del frames
    files=[(p.name,p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(assets.iterdir())]
    db=sqlite3.connect(source/'index.sqlite3')
    db.executescript('''PRAGMA journal_mode=WAL;
      CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT);
      CREATE TABLE catalogs(revision TEXT PRIMARY KEY,body TEXT);
      CREATE TABLE ready(revision TEXT,gid TEXT,available INTEGER,PRIMARY KEY(revision,gid));
      CREATE TABLE files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT);
      CREATE INDEX files_gid ON files(gid,path);
    ''')
    books=[];revision='a'*64
    for i in range(args.books):
        gid=str(i+1);directory=f'book-{gid}';folder=source/'books'/directory;folder.mkdir(parents=True)
        group=i//3
        title=f'[Studio {group:04} (Artist {group:04})] Journey {group:04} Vol. {i%3+1}'
        books.append(dict(id=gid,rank=i,title=title,directory=directory,time=args.books-i))
        for name,length,sha in files:
            os.link(assets/name,folder/name)
            db.execute('INSERT INTO files VALUES(?,?,?,?,?)',(gid,name,directory,length,sha))
        db.execute('INSERT INTO ready VALUES(?,?,1)',(revision,gid))
    db.execute('INSERT INTO catalogs VALUES(?,?)',(revision,json.dumps(dict(schema=1,orderSource='ehviewer-downloads-time-desc',orderVerified=True,books=books))))
    db.execute('INSERT INTO state VALUES(?,?)',('active',revision));db.commit();db.close()
    identity=Identity(root/'state');identity.set_password(b'fixture-pass-123')
    reader=Reader(source,identity,ThumbnailCache(root/'state'))
    manual=ManualStore(root/'manual',forbidden=(source,root/'state'))
    for i in range(3):
        selected=[assets/'00000003.webp',assets/'00000001.jpg',assets/'00000002.gif']
        data=[p.read_bytes() for p in selected]
        manifest=dict(title=f'[Manual Artist] Manual Story {i+1}',files=[dict(name=p.name,size=len(b),sha256=hashlib.sha256(b).hexdigest(),modifiedUtcTicks=639000000000000000+n) for n,(p,b) in enumerate(zip(selected,data))])
        upload=manual.start(manifest)['uploadId']
        for n,b in enumerate(data,1):manual.receive(upload,n,io.BytesIO(b),len(b))
        manual.commit(upload)
    second=Reader(manual.root,identity,ThumbnailCache(manual.root/'.cache'),library_id=manual.library_id,order_policy=POLICY,cache_root=manual.root/'.cache')
    print(json.dumps({'fixtureRoot':str(root),'books':args.books,'manualBooks':3,'port':args.port}),flush=True)
    try:
        with Server(('127.0.0.1',args.port),reader,keep_alive=True,manual_store=manual,manual_reader=second) as server:server.serve_forever()
    finally:second.close();reader.close()


if __name__=='__main__':main()
