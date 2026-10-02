"""Synthetic naming evidence; no media, live catalog, transliterator or network service."""
import json
import unittest
from unittest.mock import patch
from authors import AuthorIndex, parse_credit, variant_keys
from series import SeriesIndex, parse_series_title
import test_related as fixtures
books=fixtures.books


class ExpandedAuthors(unittest.TestCase):
    def test_kana_and_long_vowels_are_candidates_not_identity(self):
        for a,b in [('あおい','アオイ'),('ｱｵｲ','あおい'),('Satō','Satoo'),('Satou','Satoo')]:
            data=books(f'[{a}] 星空 1',f'[{b}] 星空 2')
            index=AuthorIndex(data);choice=index.options('1')[0]['id']
            self.assertEqual(index.selection('1',choice)[1],('1',))
            self.assertEqual(index.details('1',choice,expanded=True)[2],{'2'})
            self.assertEqual(SeriesIndex(data,index).options('1',True),[])
        for a,b in [('Sato','Satou'),('Alice','Alicee'),('葵','Aoi'),('青井','葵')]:
            self.assertFalse(variant_keys(a)&variant_keys(b))

    def test_explicit_alias_syntax_and_circle_roles(self):
        for value in ('[花子 / Hanako] 夜空','[Hanako / 花子] 夜空',
                      '[花子 (旧名: 華子)] 夜空','[Alice aka OldAlice] Night',
                      '[Team (花子 (別名: Hanako))] 夜空','[Team (花子 / Hanako)] 夜空'):
            credit=parse_credit(value)
            self.assertEqual(len(credit.artists),1,value);self.assertEqual(len(credit.aliases),1,value)
        # Unmarked parentheses retain the EH circle(artist) meaning.
        c=parse_credit('[花子 (Hanako)] 夜空')
        self.assertEqual((c.circle,c.artists,c.aliases),('花子',('Hanako',),()))
        for value in ('[Alice / Bob] Night','[Alice (旧名: 汉化组)] Night','[Team (A (B))] Night'):
            self.assertFalse(parse_credit(value).artists,value)

    def test_declared_old_name_bilingual_and_repeated_evidence(self):
        data=books('[花子 (旧名: 華子)] 夜空 1','[華子] 夜空 2','[花子 / Hanako] 夜空 3','[Hanako] 夜空 4',
                   '[花子 (旧名: 華子)] 別作品')
        index=AuthorIndex(data)
        for gid in ('1','2','3','4'):
            self.assertEqual(index.selection(gid,index.options(gid)[0]['id'])[1],('1','2','3','4','5'))
        self.assertGreaterEqual(index.alias_support['華子'],2)
        self.assertEqual(SeriesIndex(data,index).options('1',True)[0]['count'],4)

    def test_alias_conflicts_removal_cycles_and_no_chains(self):
        data=books('[Alice aka Old] Night','[Old] Night','[Bob aka Old] Other')
        index=AuthorIndex(data)
        self.assertEqual(index.options('2')[0]['count'],1)
        self.assertEqual(index.options('2',expanded=True)[0]['count'],1)
        fewer=AuthorIndex(data[:2],index)
        self.assertEqual(fewer.options('2')[0]['count'],2)
        self.assertEqual(index.options('2')[0]['count'],1)
        chained=AuthorIndex(books('[Alice aka Beta] A','[Beta aka Gamma] B','[Gamma] C'))
        self.assertEqual(chained.options('3')[0]['count'],1)
        cycle=AuthorIndex(books('[Alice aka Beta] A','[Beta aka Alice] B'))
        self.assertEqual(cycle.options('1')[0]['count'],1)

    def test_circle_candidates_require_two_distinct_books(self):
        data=books('[Team (Alice)] Night 1','[Team (Alice)] Night 2','[Team] Night 3','[Alice] Night 4')
        once=AuthorIndex(data[:1]+data[2:])
        self.assertEqual(once.options('3',expanded=True),[])
        index=AuthorIndex(data);choice=index.options('1')[0]['id']
        self.assertEqual(index.details('1',choice,True)[1],('1','2','4'))
        option,ids,possible=index.details('1',choice,expanded=True)
        self.assertEqual(ids,('1','2','3','4'));self.assertEqual(possible,{'3'})
        self.assertEqual(index.notes(index.group_for[choice],possible),{'3':'circle'})
        self.assertEqual(index.options('3'),[])
        inferred=index.options('3',expanded=True)[0]
        self.assertEqual(index.details('3',inferred['id'],expanded=True)[2],{'3'})
        self.assertFalse(index.creators['3'])
        self.assertEqual(SeriesIndex(data,index).options('3',True),[])
        with self.assertRaises(KeyError):index.details('4',inferred['id'],expanded=True)

    def test_circle_conflict_and_coauthors_block_inference(self):
        for title in ('[Team (Bob)] Other','[Team (Alice, Bob)] Other'):
            index=AuthorIndex(books('[Team (Alice)] One',title,'[Team] Unknown'))
            self.assertEqual(index.options('3',expanded=True),[])
        data=books('[Team (Alice)] One','[Team (Alice)] Two','[Team] Third','[Other] Fourth')
        data[2]['directory']='3-[Other] Third'
        self.assertEqual(AuthorIndex(data).options('3',expanded=True),[])

    def test_circle_conflict_invalidation_and_reorder_keep_source(self):
        data=books('[Team (Alice)] One','[Team (Alice)] Two','[Team] Third')
        index=AuthorIndex(data);choice=index.options('3',expanded=True)[0]['id']
        reordered=AuthorIndex(list(reversed(data)),index)
        self.assertEqual(reordered.details('3',choice,expanded=True)[1],('3','2','1'))
        conflict={**data[1],'title':'[Team (Bob)] Two','directory':'2-[Team (Bob)] Two'}
        changed=AuthorIndex([data[0],conflict,data[2]],reordered)
        self.assertEqual(changed.options('3',expanded=True),[])
        self.assertEqual(index.details('3',choice,expanded=True)[1],('1','2','3'))


class ExpandedSeries(unittest.TestCase):
    def index(self,*titles):
        data=books(*titles);return SeriesIndex(data,AuthorIndex(data))

    def test_extra_markers_and_no_embedded_word_stripping(self):
        for part in ('番外','番外編','後日談','后日谈','特別編','特别篇','外伝','外传','续篇','続編','epilogue','after story','extra chapter','special'):
            index=self.index('[Alice] 星空','[Alice] 星空 '+part)
            self.assertEqual(index.options('1',True)[0]['count'],2,part)
            self.assertEqual(index.part_labels['2'],part)
        for title in ('Extraordinary Night','Specialist','続ける日々'):
            self.assertEqual(parse_series_title('[Alice] '+title).root,title)

    def test_same_title_no_volume_is_possible_not_sequel(self):
        index=self.index('[Alice] 星空','[Alice] 星空','[Bob] 星空')
        self.assertEqual(index.options('1'),[])
        option=index.options('1',True)[0]
        self.assertEqual((option['count'],option['possibleCount']),(2,2))
        self.assertEqual(index.group_notes[index.expanded_group_for[option['id']]],{'1':'seriesTitle','2':'seriesTitle'})
        self.assertEqual(index.options('3',True),[])

    def test_edition_is_not_a_sequel(self):
        for suffix in ('',' 1'):
            index=self.index('[Alice] 星空'+suffix+' [Chinese]','[Alice] 星空'+suffix+' [Japanese]')
            option=index.options('1',True)[0]
            self.assertEqual(set(index.group_notes[index.expanded_group_for[option['id']]].values()),{'edition'})
        index=self.index('[Alice] 星空 1 [Chinese]','[Alice] 星空 2 [Japanese]')
        self.assertEqual(index.options('1',True)[0]['possibleCount'],0)
        index=self.index('[Alice] 星空：帰還 [Chinese]','[Alice] 星空：帰還 [Japanese]')
        choice=index.options('1',True)[0]['id']
        self.assertEqual(set(index.group_notes[index.expanded_group_for[choice]].values()),{'edition'})

    def test_extra_label_does_not_disappear_after_volume(self):
        for value in ('星空 1 番外','星空 1 [番外]','星空 [Vol. 1] [番外]'):
            part=parse_series_title('[Alice] '+value).part
            self.assertIn('1',part);self.assertIn('番外',part)
        index=self.index('[Alice] 星空 1 [Chinese]','[Alice] 星空 1 番外 [Japanese]')
        self.assertEqual(index.options('1',True)[0]['possibleCount'],0)

    def test_subtitles_without_volume_are_one_hop_candidates(self):
        index=self.index('[Alice] 星空','[Alice] 星空 ～出発～','[Alice] 星空：帰還','[Bob] 星空 ～出発～','[Alice] 別作品：帰還')
        option=index.options('2',True)[0]
        self.assertEqual(index.details('2',option['id'])[1],('1','2','3'))
        self.assertEqual(set(index.group_notes[index.expanded_group_for[option['id']]].values()),{'seriesSubtitle'})
        self.assertEqual(index.options('4',True),[]);self.assertEqual(index.options('5',True),[])

    def test_folder_fallback_does_not_override_valid_title(self):
        data=books('[Alice]','[Alice] 星空 2','[Alice] 別作品 3','[Alice] Sketch 2025.03')
        data[0]['directory']='1-[Alice] 星空 1'
        data[2]['directory']='3-[Alice] 星空 3'
        data[3]['directory']='4-[Alice] 星空 4'
        index=SeriesIndex(data,AuthorIndex(data));option=index.options('1',True)[0]
        self.assertEqual(index.details('1',option['id'])[1],('1','2'))
        self.assertEqual(index.group_notes[index.expanded_group_for[option['id']]],{'1':'directory'})
        self.assertEqual(index.part_labels['1'],'1')
        data[3]['title']='[Alice] Sketch ２０２５.０３'
        index=SeriesIndex(data,AuthorIndex(data))
        self.assertEqual(index.details('1',index.options('1',True)[0]['id'])[1],('1','2'))

    def test_generic_dates_ips_and_typos_stay_separate(self):
        for a,b in [('作品集','作品集 番外'),('短篇：旅途','短篇：帰還'),
                    ('Sketch 2025.03','Sketch 2025.04'),('作品A (Fate)','作品B (Fate)'),('Star Sky','Star Skye')]:
            index=self.index('[Alice] '+a,'[Alice] '+b)
            self.assertEqual(index.options('1',True),[],(a,b))

    def test_bilingual_numbered_series_and_selection_stability(self):
        data=books('[Aoi] Star Sky 1','[Aoi] Star Sky 2')
        a=AuthorIndex(data);old=SeriesIndex(data,a);choice=old.options('1',True)[0]['id']
        more=data+books('[葵] 星空 第3巻')
        more[2]={**more[2],'id':'3','directory':'3-[Aoi] Star Sky Vol. 3'}
        updated=SeriesIndex(more,AuthorIndex(more,a),old)
        self.assertEqual(updated.options('1',True)[0]['id'],choice)
        self.assertEqual(updated.details('1',choice)[1],('1','2','3'))

    def test_twenty_thousand_reorder_and_budget(self):
        data=books(*(f'[Alice] Night: Journey {i}A' for i in range(20000)))
        with patch('builtins.open',side_effect=AssertionError('no media reads')):
            author=AuthorIndex(data);index=SeriesIndex(data,author)
        option=index.options('1',True)[0]
        self.assertEqual(option['count'],20000)
        self.assertLessEqual(index.cost,index.budget);self.assertLessEqual(author.cost,author.budget)
        with patch('authors.parse_credit',side_effect=AssertionError('reparse')),patch('series.parse_series_title',side_effect=AssertionError('reparse')):
            reverse=list(reversed(data));a=AuthorIndex(reverse,author);reordered=SeriesIndex(reverse,a,index)
        self.assertEqual(reordered.details('1',option['id'])[1][0],'20000')
        self.assertEqual(reordered.parsed_count,0)


class ExpandedHTTP(unittest.TestCase):
    setUp=fixtures.RelatedHTTPTests.setUp
    tearDown=fixtures.RelatedHTTPTests.tearDown
    publish=fixtures.RelatedHTTPTests.publish
    file=fixtures.RelatedHTTPTests.file
    server=fixtures.RelatedHTTPTests.server
    request=fixtures.RelatedHTTPTests.request
    def test_v3_circle_contract_and_legacy_isolation(self):
        self.books=books('[Team (Alice)] Night 1','[Team (Alice)] Night 2','[Team] Night 3')
        self.revision='d'*64;self.publish();before=list(self.db.iterdump())
        with self.server() as server:
            path='/v1/books/3/authors'
            self.assertEqual(json.loads(self.request(server,path)[2])['options'],[])
            status,_,raw=self.request(server,path+'?evidence=3');self.assertEqual(status,200)
            choice=json.loads(raw)['options'][0]
            selected=path+'/'+choice['id']+'?evidence=3&limit=50'
            status,headers,raw=self.request(server,selected);value=json.loads(raw)
            self.assertEqual(value['matchNotes'],{'3':'circle'})
            self.assertEqual(value['possibleBookIDs'],['3'])
            self.assertEqual(value['option']['evidenceVersion'],3)
            self.assertEqual(self.request(server,selected,headers['ETag'])[::2],(304,b''))
            self.assertEqual(self.request(server,selected,auth=False)[0],401)
            for suffix in ('evidence=4','evidence=3&evidence=3','evidence=','bad=1'):
                self.assertEqual(self.request(server,path+'?'+suffix)[0],400)
        self.assertEqual(list(self.db.iterdump()),before)

    def test_v3_series_evidence_paginated_and_old_client_excluded(self):
        self.books=books(*(f'[Alice] 星空：副标题{i}A' for i in range(102)))
        self.revision='e'*64;self.publish()
        with self.server() as server:
            path='/v1/books/1/series'
            self.assertEqual(json.loads(self.request(server,path)[2])['options'],[])
            choice=json.loads(self.request(server,path+'?evidence=3')[2])['options'][0]
            self.assertEqual((choice['count'],choice['possibleCount']),(102,102))
            for size,offset,count in ((50,50,50),(500,0,102),(50,20000,2)):
                status,_,raw=self.request(server,path+'/'+choice['id']+f'?evidence=3&limit={size}&offset={offset}')
                self.assertEqual(status,200);value=json.loads(raw)
                ids=[b['id'] for b in value['catalog']['books']]
                self.assertEqual(len(ids),count);self.assertEqual(set(value['matchNotes']),set(ids))
                self.assertEqual(set(value['possibleBookIDs']),set(ids))
                self.assertEqual(set(value['matchNotes'].values()),{'seriesSubtitle'})
            self.assertEqual(self.request(server,'/v1/books/999/series/'+choice['id']+'?evidence=3')[0],404)


if __name__=='__main__':unittest.main()
