import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/'tools'))
from confirmed_catalog import convert

class ConfirmedCatalogTests(unittest.TestCase):
    def test_requires_complete_tie_confirmation_and_preserves_it(self):
        d={'rows':[{'id':gid,'directory':gid+'-book','title':'synthetic','time':t} for gid,t in [('3',0),('9',20),('7',0)]],'resolvedTies':{}}
        with self.assertRaisesRegex(ValueError,'unconfirmed'):convert(d)
        d['resolvedTies']={'0':['7','3']}
        self.assertEqual([b['id'] for b in convert(d)['books']],['9','7','3'])
        d['resolvedTies']={'0':['7','7']}
        with self.assertRaisesRegex(ValueError,'unconfirmed'):convert(d)
