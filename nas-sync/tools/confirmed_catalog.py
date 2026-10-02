"""Convert the phone's confirmed order.json draft to an independent audit catalog."""
import argparse,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from server import validate_catalog

def convert(draft):
    ties=draft.get('resolvedTies',{});groups={}
    for row in draft['rows']:
        if type(row['time']) is not int:raise ValueError('invalid_time')
        groups.setdefault(row['time'],[]).append(row)
    books=[]
    for timestamp in sorted(groups,reverse=True):
        group=groups[timestamp]
        if len(group)>1:
            confirmed=ties.get(str(timestamp));by_id={r['id']:r for r in group}
            if not isinstance(confirmed,list) or len(confirmed)!=len(group) or set(confirmed)!=set(by_id):raise ValueError('unconfirmed_tied_download_order')
            group=[by_id[gid] for gid in confirmed]
        for row in group:books.append({k:row[k] for k in ['id','directory','title','time']}|{'rank':len(books)})
    cat={'schema':1,'orderSource':'ehviewer-downloads-time-desc','orderVerified':True,'resolvedTies':ties,'books':books}
    validate_catalog(cat);return cat

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--draft',required=True);p.add_argument('--out',required=True);a=p.parse_args()
    Path(a.out).write_text(json.dumps(convert(json.loads(Path(a.draft).read_text())),ensure_ascii=False,indent=2))
