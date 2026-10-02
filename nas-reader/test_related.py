import gzip
import hashlib
import json
import unittest
from unittest.mock import patch
from authors import parse_credit, key, name_key, AuthorIndex
from series import parse_series_title, series_title, SeriesIndex
import test_server as fixtures
import test_optimizations as http_fixtures


def books(*titles):
    return [dict(id=str(i+1),title=t,rank=i,time=20000-i,directory=f'{i+1}-{t}') for i,t in enumerate(titles)]


class AuthorTests(unittest.TestCase):
    def test_prefixes_and_platforms(self):
        for title in ('(C105) [Circle (Alice)] Story [Chinese] [Translator]',
                      '（例大祭12）【Circle （Alice）】 Story','[Pixiv] [Alice] Story',
                      '[Patreon] [Alice] Story','[Fanbox] Alice 2025.03 collection'):
            c=parse_credit(title);self.assertEqual(c.artists or (c.untyped,),('Alice',))
        for title in ('[Pixiv] Story without artist', '[Chinese] Story [Translator]',
                      '[Anthology] [Alice] Story', '[Circle (A (B))] X','[Circle (A 他)] X',
                      '[汉化组] Story', '[AI Generated] Story','[Alice\u202e] Story'):
            self.assertFalse(parse_credit(title).artists or parse_credit(title).untyped,title)

    def test_multiple_credits_not_one_author(self):
        for title in ('[Circle (Alice, Bob)] X','[Circle (Alice、Bob)] X','[Alice, Bob] X','[Circle (Alice × Bob)] X'):
            self.assertEqual(parse_credit(title).artists,('Alice','Bob'))

    def test_normalization(self):
        self.assertEqual(key('Ｐｏｙｅｏｐ'),key('poyeop'))
        self.assertEqual(key('Yukino Minato'),key('yukino-minato'))
        self.assertEqual(key('Satō'),key('Satou'))
        self.assertNotEqual(key('Sato'),key('Satou'))

    def test_same_circle_is_not_same_artist(self):
        b=books('[Team (Alice)] Work 1','[Team (Bob)] Work 2','[Team] Work 3','[Alice] Work 4')
        index=AuthorIndex(b)
        option=index.options('1')[0]
        self.assertEqual(index.members[option['id']],('1','4'))
        self.assertFalse(index.options('3'))

    def test_single_bilingual_book_teaches_alias_and_roman_variants(self):
        b=books('[Circle (朝凪)] Work 1','[Asanagi] Work 2','[朝凪] Work 3')
        b[0]['directory']='1-[Circle (Asanagi)] Work 1'
        index=AuthorIndex(b)
        option=index.options('1')[0]
        self.assertEqual(index.members[option['id']],('1','2','3'))
        self.assertIn('Asanagi',option['aliases'])
        self.assertEqual(index.alias_pairs,1)

    def test_standalone_bilingual_and_multiple_romanizations(self):
        b=books('[花子] Story 1','[花子] Story 2','[Hanako] Story 3','[Hana Ko] Story 4')
        b[0]['directory']='1-[Hanako] Story 1';b[1]['directory']='2-[Hana-ko] Story 2'
        index=AuthorIndex(b)
        self.assertEqual(index.options('1')[0]['count'],3)
        option,ids,possible=index.details('1',index.options('1')[0]['id'],True)
        self.assertEqual(ids,('1','2','3','4'));self.assertEqual(possible,{'4'})
        self.assertEqual(option['possibleCount'],1)

    def test_layout_similarity_is_candidate_not_identity(self):
        for a,b in [('A-B','AB'),('Hana Ko','Hanako'),('A.o.i','Aoi'),('Satō','Satou')]:
            index=AuthorIndex(books(f'[{a}] Night 1',f'[{b}] Night 2'))
            choice=index.options('1')[0]
            self.assertEqual(choice['count'],1)
            candidate,ids,possible=index.details('1',choice['id'],True)
            self.assertEqual(candidate['count'],2);self.assertEqual(possible,{'2'})
            self.assertFalse(SeriesIndex(books(f'[{a}] Night 1',f'[{b}] Night 2'),index).options('1'))

    def test_alias_addition_keeps_both_selectors_across_restart(self):
        initial=books('[Aoi] Star Sky 1','[Aoi] Star Sky 2')
        a=AuthorIndex(initial);s=SeriesIndex(initial,a)
        author=a.options('1')[0]['id'];series=s.options('1')[0]['id']
        more=books('[Aoi] Star Sky 1','[Aoi] Star Sky 2','[葵] 星空 第3巻')
        more[2]['directory']='3-[Aoi] Star Sky Vol. 3'
        for previous in (a,None):
            new=AuthorIndex(more,previous);new_series=SeriesIndex(more,new,s if previous else None)
            self.assertEqual(new.options('1')[0]['id'],author)
            self.assertEqual(new.selection('1',author)[1],('1','2','3'))
            self.assertEqual(new_series.options('1')[0]['id'],series)
            self.assertEqual(new_series.selection('1',series)[1],('1','2','3'))

    def test_alias_conflict_removal_and_previous_snapshot_immutable(self):
        b=books('[葵] Work 1','[Aoi] Work 2');b[0]['directory']='1-[Aoi] Work 1'
        first=AuthorIndex(b);identity=first.options('2')[0]['id']
        conflict={**b[0],'id':'3','title':'[青井] Work 3','directory':'3-[Aoi] Work 3'}
        second=AuthorIndex(b+[conflict],first)
        self.assertEqual(second.selection('2',identity)[1],('2',))
        self.assertEqual(first.selection('2',identity)[1],('1','2'))
        third=AuthorIndex(b,second)
        self.assertEqual(third.selection('2',identity)[1],('1','2'))

    def test_possible_candidates_are_one_hop_and_keep_rank(self):
        b=books('[A-oi] One','[葵] Two','[Other] Three','[Aoi] Four')
        b[1]['directory']='2-[Aoi] Two'
        index=AuthorIndex(b);choice=index.options('1')[0]['id']
        option,ids,possible=index.details('1',choice,True)
        self.assertEqual(ids,('1','2','4'));self.assertEqual(possible,{'2','4'})
        self.assertEqual(option['aliases'],[])
        reordered=AuthorIndex(list(reversed(b)),index)
        self.assertTrue(reordered.reordered_only)
        self.assertIs(reordered.structure,index.structure)
        self.assertEqual(reordered.details('1',choice,True)[1],('4','2','1'))

    def test_conflicting_romanization_never_joins_people(self):
        b=books('[甲子] Work 1','[乙子] Work 2','[Same] Work 3')
        b[0]['directory']='1-[Same] Work 1';b[1]['directory']='2-[Same] Work 2'
        index=AuthorIndex(b)
        self.assertEqual([index.options(str(i))[0]['count'] for i in (1,2,3)],[1,1,1])
        self.assertEqual(index.options('3')[0]['matchKind'],'name')

    def test_collaboration_does_not_bridge_authors(self):
        index=AuthorIndex(books('[Team (Alice, Bob)] X','[Alice] Y','[Bob] Z'))
        self.assertEqual(len(index.options('1')),2)
        self.assertEqual({index.members[o['id']] for o in index.options('1')},{('1','2'),('1','3')})

    def test_saved_directory_credit_fills_missing_display_artist(self):
        b=books('Night 1','[Team] Night 2','[Alice] Night 3','[Team (Bob, Carol)] Night 4')
        b[0]['directory']='1-[Team (Alice)] Night 1'
        b[1]['directory']='2-[Team (Alice)] Night 2'
        b[3]['directory']='4-[Team (Alice)] Night 4'
        index=AuthorIndex(b)
        self.assertEqual(index.selection('1',index.options('1')[0]['id'])[1],('1','2','3'))
        self.assertEqual({o['name'] for o in index.options('4')},{'Bob','Carol'})

    def test_rename_reorder_and_parser_reuse(self):
        b=books('[Alice] A','[Alice] B','[Bob] C');first=AuthorIndex(b)
        reordered=list(reversed(b))
        second=AuthorIndex(reordered,first)
        self.assertEqual(second.parsed_count,0)
        self.assertEqual(second.members[second.options('1')[0]['id']],('2','1'))
        reordered[0]={**reordered[0],'title':'[Alice] C'}
        third=AuthorIndex(reordered,second)
        self.assertEqual(third.parsed_count,1);self.assertEqual(third.options('1')[0]['count'],3)

    def test_large_index_budget_and_no_media(self):
        b=books(*(f'[Artist {i%200}] Story {i}' for i in range(10094)))
        with patch('builtins.open',side_effect=AssertionError('opened file')):
            index=AuthorIndex(b)
        self.assertLessEqual(index.cost,index.budget)
        self.assertEqual(index.options('1')[0]['count'],51)
        with patch.object(AuthorIndex,'budget',100):
            with self.assertRaises(ValueError):AuthorIndex(b[:1])


class SeriesTests(unittest.TestCase):
    def test_new_shorthand_sequel_and_subtitle_forms(self):
        for a,b in [('Star Sky Vol. 1','Star Sky v02'),('星空','続・星空'),
                    ('星空 1 ～出発～','星空 2 ～帰還～'),('Night v01: Start','Night v02: Return'),
                    ('星空 1 ～出発 7～','星空 2 ～帰還 8～')]:
            data=books('[Aoi] '+a,'[Aoi] '+b);index=SeriesIndex(data,AuthorIndex(data))
            self.assertEqual(index.options('1')[0]['count'],2,(a,b))
        p=parse_series_title('[Aoi] 星空 2 ～帰還～')
        self.assertEqual((p.root,p.part,p.subtitle),('星空','2','帰還'))

    def test_numeric_title_and_dates_are_not_parts(self):
        for a,b in [('Exhibition 2023','Exhibition 2024'),('Sketchbook 2025.03','Sketchbook 2025.04'),
                    ('Area51','Area52'),('Agent 007','Agent 008')]:
            data=books('[Aoi] '+a,'[Aoi] '+b)
            self.assertFalse(SeriesIndex(data,AuthorIndex(data)).options('1'),(a,b))
        for title in ('3x3 Eyes Vol. 1','1984 Vol. 2'):
            parsed=parse_series_title('[Aoi] '+title)
            self.assertEqual(parsed.root,'3x3 Eyes' if title.startswith('3x3') else '1984')
        self.assertEqual(series_title('[Aoi] 続ける日々'),('続ける日々',False))

    def test_reorder_and_one_change_parse_only_necessary_rows(self):
        data=books(*(f'[Aoi] Night Vol. {i+1}' for i in range(10094)))
        author=AuthorIndex(data);series=SeriesIndex(data,author)
        reversed_data=list(reversed(data))
        with patch('authors.parse_credit',side_effect=AssertionError('author reparse')),patch('series.parse_series_title',side_effect=AssertionError('series reparse')):
            reordered_author=AuthorIndex(reversed_data,author)
            reordered_series=SeriesIndex(reversed_data,reordered_author,series)
        self.assertTrue(reordered_series.reordered_only)
        self.assertEqual(reordered_series.parsed_count,0)
        choice=series.options('1')[0]['id']
        self.assertEqual(reordered_series.selection('1',choice)[1],tuple(str(i) for i in range(10094,0,-1)))
        reversed_data[0]={**reversed_data[0],'title':'[Aoi] Other Vol. 2'}
        changed_author=AuthorIndex(reversed_data,reordered_author)
        changed_series=SeriesIndex(reversed_data,changed_author,reordered_series)
        self.assertEqual(changed_series.parsed_count,1)
        self.assertEqual(len(series.selection('1',choice)[1]),10094)
        self.assertEqual(len(changed_series.selection('1',choice)[1]),10093)

    def test_collaboration_group_dedup_and_budget(self):
        data=books(*(f'[Aoi, Beni] Night Vol. {i}' for i in range(1,2001)))
        index=SeriesIndex(data,AuthorIndex(data))
        self.assertEqual(len(index.options('1')),1)
        self.assertEqual(index.options('1')[0]['count'],2000)
        with patch.object(SeriesIndex,'budget',100):
            with self.assertRaises(ValueError):SeriesIndex(data,AuthorIndex(data))
    def test_parts(self):
        for title in ('[A] Night 2 [Chinese]','[A] Night Vol. 2','[A] Night Chapter 3',
                      '[A] Night 第2巻','[A] Night 2.5','[A] Night 前編','[A] Night 後編','[A] Night III'):
            self.assertEqual(series_title(title),('Night',True),title)
        self.assertEqual(series_title('[A] Night (Fate) [Chinese]'),('Night',False))

    def test_same_series_not_same_ip(self):
        b=books('[Alice] Night 1 (Fate)','[Alice] Night 2 (Fate)',
                '[Alice] Different story (Fate)','[Bob] Night 3 (Fate)','[Alice] Night (Fate)')
        index=SeriesIndex(b,AuthorIndex(b))
        self.assertEqual(index.selection('1',index.options('1')[0]['id'])[1],('1','2','5'))
        self.assertFalse(index.options('3'));self.assertFalse(index.options('4'))

    def test_unnumbered_duplicates_do_not_pretend_sequels(self):
        b=books('[A] Night [Chinese]','[A] Night [English]')
        self.assertFalse(SeriesIndex(b,AuthorIndex(b)).options('1'))

    def test_series_bilingual_title(self):
        b=books('[花子] 夜空 第1巻','[Hanako] Night sky Vol. 2','[花子] 夜空 後編')
        b[0]['directory']='1-[Hanako] Night Sky Vol. 1'
        b[2]['directory']='3-[Hanako] Night Sky Part 3'
        index=SeriesIndex(b,AuthorIndex(b))
        self.assertEqual(index.options('1')[0]['count'],3)

    def test_generic_and_dates(self):
        for title in ('[A] 作品集 1','[A] Collection 2','[A] Art 2025.03 set'):
            self.assertIsNone(series_title(title))

    def test_wrapped_volume_and_sequel_markers(self):
        for suffix in ('(前編)','(後編)','[第2巻]','(Vol. 3) [Chinese]'):
            self.assertEqual(series_title('[Alice] Night '+suffix),('Night',True))
        b=books('[Alice] Night (前編) (Fate)','[Alice] Night (後編) (Fate)')
        index=SeriesIndex(b,AuthorIndex(b))
        self.assertEqual(index.options('1')[0]['count'],2)


class RelatedHTTPTests(unittest.TestCase):
    setUp=fixtures.ReaderTests.setUp
    tearDown=fixtures.ReaderTests.tearDown
    publish=fixtures.ReaderTests.publish
    file=fixtures.ReaderTests.file
    server=http_fixtures.OptimizationTests.server
    request=http_fixtures.OptimizationTests.request

    def prepare(self):
        for b in self.books:b['title']=f'[Alice] Night {b["id"]}'
        self.revision='b'*64;self.publish()

    def test_candidate_contract_is_opt_in_and_page_scoped(self):
        self.books=books(*(f'[{"Hana-ko" if i%2 else "Hanako"}] Night {i}' for i in range(102)))
        self.revision='d'*64;self.publish();before=list(self.db.iterdump())
        with self.server() as server:
            base='/v1/books/1/authors'
            status,_,raw=self.request(server,base);choice=json.loads(raw)['options'][0]
            self.assertEqual(choice['count'],51);self.assertNotIn('possibleCount',choice)
            status,_,raw=self.request(server,base+'?includePossible=1');option=json.loads(raw)['options'][0]
            self.assertEqual((option['count'],option['possibleCount']),(102,51))
            selected=base+'/'+option['id']+'?offset=50&limit=50&includePossible=1'
            status,headers,raw=self.request(server,selected);value=json.loads(raw)
            self.assertEqual(status,200)
            self.assertEqual([b['rank'] for b in value['catalog']['books']],list(range(50,100)))
            self.assertEqual(value['possibleBookIDs'],[str(i+1) for i in range(51,100,2)])
            self.assertEqual(self.request(server,selected,headers['ETag'])[::2],(304,b''))
            self.assertEqual(self.request(server,selected,auth=False)[0],401)
            self.assertEqual(self.request(server,base+'?includePossible=yes')[0],400)
            self.assertEqual(self.request(server,base+'?includePossible=1&includePossible=0')[0],400)
            self.assertEqual(self.request(server,'/v1/books/1/series?includePossible=1')[0],400)
        self.assertEqual(before,list(self.db.iterdump()))

    def test_series_cache_reused_after_author_query_sees_reorder(self):
        self.prepare();first=self.reader.related('1','series');choice=first['options'][0]['id']
        old=self.reader.series_index
        self.books=list(reversed(self.books))
        for i,b in enumerate(self.books):b.update(rank=i,time=100-i)
        self.revision='e'*64;self.publish()
        self.reader.related('1','authors')
        with patch('series.parse_series_title',side_effect=AssertionError('reparsed')):
            result=self.reader.related('1','series',choice,limit=50)
        self.assertTrue(self.reader.series_index.reordered_only)
        self.assertIsNot(old,self.reader.series_index)
        self.assertEqual([b['id'] for b in result['catalog']['books']],['3','2','1'])

    def test_options_auth_page_and_conditional(self):
        self.prepare();before=list(self.db.iterdump())
        with self.server() as server:
            for kind in ('authors','series'):
                path=f'/v1/books/1/{kind}'
                self.assertEqual(self.request(server,path,auth=False)[0],401)
                status,headers,raw=self.request(server,path);self.assertEqual(status,200)
                options=json.loads(raw);self.assertEqual(options['options'][0]['count'],3)
                self.assertEqual(self.request(server,path,headers['ETag'])[::2],(304,b''))
                selected=path+'/'+options['options'][0]['id']+'?offset=0&limit=50'
                status,_,raw=self.request(server,selected);value=json.loads(raw)
                self.assertEqual(status,200);self.assertEqual([b['rank'] for b in value['catalog']['books']],[0,1,2])
                self.assertFalse(value['catalog']['books'][2]['available'])
                self.assertEqual(self.request(server,selected,auth=False)[0],401)
        self.assertEqual(before,list(self.db.iterdump()))

    def test_invalid_parameters_scope_and_unknown(self):
        self.prepare()
        with self.server() as server:
            for query in ('limit=51','offset=-1','limit=50&offset=1','limit=50&limit=100','evil=1'):
                self.assertEqual(self.request(server,'/v1/books/1/authors?'+query)[0],400)
            self.assertEqual(self.request(server,'/v1/books/99/authors')[0],404)
            self.assertEqual(self.request(server,'/v1/books/1/authors/'+'0'*64)[0],404)

    def test_new_snapshot_and_same_revision_file_updates(self):
        self.prepare();first=self.reader.related('1','authors');option=first['options'][0]
        old=self.reader.related('1','authors',option['id'],limit=50)
        self.db.execute("UPDATE files SET sha=? WHERE gid='1' AND path='.thumb'",('e'*64,));self.db.commit()
        new=self.reader.related('1','authors',option['id'],limit=50)
        self.assertNotEqual(old['catalog']['books'][0]['coverIdentity'],new['catalog']['books'][0]['coverIdentity'])
        original=self.reader.author_index
        self.assertIs(original,self.reader.author_index)
        self.books=list(reversed(self.books))
        for i,b in enumerate(self.books):b.update(rank=i,time=100-i)
        self.revision='c'*64;self.publish()
        new=self.reader.related('1','authors',option['id'],limit=50)
        self.assertEqual([b['id'] for b in new['catalog']['books']],['3','2','1'])
        self.assertEqual(self.reader.author_index.parsed_count,0)

    def test_large_pagination_clamped_and_original_rank(self):
        self.books=books(*(f'[Artist {i%2}] Night {i}' for i in range(10094)))
        self.revision='d'*64;self.publish()
        options=self.reader.related('2','authors');choice=options['options'][0]['id']
        for size in (50,500):
            result=self.reader.related('2','authors',choice,offset=0,limit=size)
            self.assertEqual(len(result['catalog']['books']),size)
            self.assertEqual([b['rank'] for b in result['catalog']['books']],list(range(1,2*size,2)))
        result=self.reader.related('2','authors',choice,offset=20000,limit=500)
        self.assertEqual(result['offset'],5000);self.assertEqual(len(result['catalog']['books']),47)


if __name__=='__main__':unittest.main()
