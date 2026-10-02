"""Synthetic titles only; regression and negative controls for opt-in discovery."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from authors import AuthorIndex, Credit, parse_credit, credit_tokens, variant_keys
from series import SeriesIndex
from relaxed import close_title
from related_cache import RelatedDiskCache
from test_related import books
import test_related as fixtures


def indexes(*titles):
    data=books(*titles);a=AuthorIndex(data);return data,a,SeriesIndex(data,a)


class CreditStructure(unittest.TestCase):
    def test_supplied_circle_qualifier_and_both_directions(self):
        for prefix in ('[架空工房(仮) (桜田明)]','【架空工房（仮） （桜田明）】','[架空工房 (仮) (桜田明)]'):
            data,a,s=indexes('[桜田明] One',prefix+' Two')
            self.assertEqual(parse_credit(prefix).artists,('桜田明',))
            for gid in ('1','2'):
                choice=a.options(gid)[0]
                self.assertEqual(choice['name'],'桜田明');self.assertEqual(choice['count'],2)
                self.assertEqual(a.selection(gid,choice['id'])[1],('1','2'))

    def test_qualifier_is_never_an_artist_and_coauthors_stay_separate(self):
        self.assertEqual(parse_credit('[架空工房(仮)] Title').artists,())
        self.assertEqual(parse_credit('[Team(v2) (Alice, Bob)] Title').artists,('Alice','Bob'))
        _,a,_=indexes('[Team(仮) (Alice)] One','[Team(仮) (Bob)] Two','[Alice] Three')
        self.assertEqual(a.options('1')[0]['count'],2);self.assertEqual(a.options('2')[0]['count'],1)
        for value in ('[Circle (Alice) (Bob)]','[Circle (A (B))]','[Circle (Alice]','[Circle (((((Alice)))))]'):
            self.assertEqual(parse_credit(value),Credit())

    def test_complete_known_name_only_and_opt_in(self):
        _,a,_=indexes('[桜田明] One','[Team (桜田明 | Bob)] Two')
        self.assertEqual(a.options('2',expanded=True),[])
        source=a.options('2',expanded=True,known=True)[0]
        option,ids,possible=a.details('2',source['id'],expanded=True,known=True)
        self.assertEqual(ids,('1','2'));self.assertEqual(possible,{'2'})
        self.assertEqual(a.notes(a.selector_group(source['id']),possible),{'2':'creditName'})
        exact=a.options('1')[0]['id']
        self.assertEqual(a.details('1',exact,expanded=True,known=True)[1],('1','2'))
        self.assertEqual(a.creators['2'],());self.assertEqual(a.alias_pairs,0)

    def test_fallback_does_not_read_work_ip_translator_or_partial_name(self):
        for value in ('[Team (桜田明子 / Bob)] Story','[Team] 桜田明 [Bob]',
                      'Story [桜田明]','[Team (桜田明 / 翻訳者)] Story',
                      '[Anthology] [桜田明] Story','[Team (桜田明 / Bob] Story',
                      '[Team (((((桜田明)))))] Story'):
            data,a,_=indexes('[桜田明] One',value)
            self.assertNotIn('2',a.known_choices,value)
        self.assertEqual(credit_tokens('[Team] Story (桜田明)'),('team',))

    def test_multiple_known_people_and_conflicting_sources(self):
        data,a,_=indexes('[Alice] A','[Bob] B','[Team (Alice / Bob)] C')
        self.assertEqual(len(a.options('3',expanded=True,known=True)),2)
        self.assertEqual(a.options('1')[0]['count'],1)
        data[2]['directory']='3-[Team (Alice / Carol)] C'
        a=AuthorIndex(data);self.assertNotIn('3',a.known_choices)
        data[2]['directory']='3-[Bob] C'
        a=AuthorIndex(data);self.assertEqual(a.options('3')[0]['name'],'Bob');self.assertNotIn('3',a.known_choices)

    def test_known_registry_change_reorder_and_failed_prefix_change(self):
        data,a,_=indexes('[Alice] A','[Bob] B','[Team (Alice / Unknown)] C')
        choice=a.options('3',expanded=True,known=True)[0]['id']
        reverse=AuthorIndex(list(reversed(data)),a)
        self.assertEqual(reverse.parsed_count,0)
        self.assertEqual(reverse.details('3',choice,expanded=True,known=True)[1],('3','1'))
        changed=copy.deepcopy(data);changed[2]['title']='[Team (Bob / Unknown)] C';changed[2]['directory']='3-'+changed[2]['title']
        updated=AuthorIndex(changed,a)
        self.assertFalse(updated.relationships_reused)
        self.assertEqual(updated.options('3',expanded=True,known=True)[0]['name'],'Bob')
        removed=AuthorIndex(data[1:],a);self.assertNotIn('3',removed.known_choices)

    def test_no_circle_ambiguous_alias_or_candidate_chain(self):
        _,a,_=indexes('[Team (Alice)] A','[Team (Alice)] B','[Group (Team / Unknown)] C',
                      '[NewName / Unknown] D','[Group (NewName / Missing)] E')
        self.assertNotIn('3',a.known_choices);self.assertNotIn('5',a.known_choices)
        _,a,_=indexes('[Alice aka Old] A','[Bob aka Old] B','[Group (Old / Unknown)] C')
        self.assertNotIn('3',a.known_choices)


class RelaxedNaming(unittest.TestCase):
    def test_author_layout_and_roman_order_are_candidates_only(self):
        for left,right in (('桜田明','桜田 明'),('桜田明','桜田・明'),('Hanako Yamada','Yamada Hanako')):
            _,a,s=indexes(f'[{left}] 星空物語 1',f'[{right}] 星空物語 2')
            choice=a.options('1')[0]['id']
            self.assertEqual(a.options('1')[0]['count'],1)
            self.assertEqual(a.details('1',choice,expanded=True)[2],{'2'})
            self.assertEqual(s.options('1',True),[])
            self.assertEqual(s.relaxed_options('1')[0]['count'],2)
        for a,b in (('桜田明','桜田明子'),('葵','Aoi'),('Sato','Satou')):
            self.assertFalse(variant_keys(a)&variant_keys(b))

    def test_punctuation_small_typo_and_symmetric_direct_results(self):
        for left,right in (('星空物語','星空・物語'),('Star Light Story','Star-Light Story'),('Starlight Story','Starlight Storys')):
            _,a,s=indexes(f'[Alice] {left} 1',f'[Alice] {right} 2')
            for gid in ('1','2'):
                option=s.relaxed_options(gid)[0]
                self.assertEqual(s.relaxed_details(gid,option['id'])[1],('1','2'))
                self.assertGreater(option['possibleCount'],0)
        self.assertFalse(close_title('Area51 Story','Area52 Story'))
        self.assertFalse(close_title('短故事甲','短故事乙'))

    def test_fuzzy_never_crosses_author_and_no_transitive_chain(self):
        _,a,s=indexes('[Alice] abcdef 1','[Alice] abcdeg 2','[Alice] abcdgg 3','[Bob] abcdef 4')
        option=s.relaxed_options('1')[0]
        self.assertEqual(s.relaxed_details('1',option['id'])[1],('1','2'))
        self.assertEqual(s.relaxed_options('4'),[])
        _,a,s=indexes('[Hana-ko] Starlight Story 1','[Hanako] Starlight Storys 2')
        self.assertEqual(s.relaxed_options('1'),[])

    def test_weak_credit_can_find_series_but_cannot_become_identity(self):
        _,a,s=indexes('[Alice] Nightstar 1','[Group (Alice / Missing)] Nightstar 2')
        self.assertFalse(a.creators['2']);self.assertEqual(s.options('2',True),[])
        option=s.relaxed_options('2')[0];_,ids,possible,notes=s.relaxed_details('2',option['id'])
        self.assertEqual(ids,('1','2'));self.assertEqual(notes['2'],'authorSeries')
        _,a,s=indexes('[Alice] Nightstar','[Group (Alice / Missing)] Nightstar')
        self.assertEqual(s.relaxed_options('2'),[])

    def test_same_work_bilingual_editions_give_candidate_not_alias(self):
        data,a,s=indexes('[甲作者] 六文字以上の作品 第1巻 [Chinese]',
                         '[AuthorA] 六文字以上の作品 第1巻 [English]','[AuthorA] Different Work 1')
        peers=s.relaxed['work_peers'];self.assertEqual(peers['甲作者'],('authora',))
        choice=a.options('1')[0]['id']
        self.assertEqual(a.options('1')[0]['count'],1)
        _,ids,possible=a.details('1',choice,expanded=True,work_peers=peers)
        self.assertEqual(ids,('1','2','3'));self.assertEqual(a.alias_pairs,0)
        self.assertEqual(a.notes(a.selector_group(choice),possible,peers),{'2':'workCredit','3':'workCredit'})
        self.assertEqual(s.options('1',True),[])

    def test_reverse_evidence_rejects_shared_ip_short_root_same_language_or_part(self):
        for left,right in (('[甲作者] Work 1 [Chinese]','[AuthorA] Work 1 [English]'),
                           ('[甲作者] 六文字以上の作品 1 [Chinese]','[AuthorA] 六文字以上の作品 2 [English]'),
                           ('[甲作者] 六文字以上の作品 1 [Chinese]','[AuthorA] 六文字以上の作品 1 [Chinese]'),
                           ('[甲作者] 別の作品長い名前 1 (Shared IP) [Chinese]','[AuthorA] 六文字以上の作品 1 (Shared IP) [English]')):
            _,_,s=indexes(left,right);self.assertEqual(s.relaxed['work_peers'],{})
        _,_,s=indexes('[甲作者] 六文字以上の作品 1 [Chinese]','[AuthorA] 六文字以上の作品 1 [English]',
                       '[乙作者] もう一つ長い作品 1 [Chinese]','[AuthorA] もう一つ長い作品 1 [English]')
        self.assertEqual(s.relaxed['work_peers'],{})

    def test_short_legacy_series_and_existing_strong_count_remain(self):
        for root in ('星空','Nightstar'):
            _,a,s=indexes(f'[Alice] {root} 1',f'[Alice] {root} 2')
            self.assertEqual(s.relaxed_options('1'),s.options('1',True))
            self.assertEqual(s.relaxed_options('1')[0]['possibleCount'],0)

    def test_fuzzy_work_is_bounded_but_exact_key_still_works(self):
        _,a,s=indexes(*(f'[Alice] A Long Different Story {i}A' for i in range(300)),
                       '[Alice] Unique World Story 1','[Alice] Unique・World Story 2')
        with patch('relaxed.close_title',side_effect=AssertionError('unbounded fuzzy scan')):
            self.assertEqual(s.relaxed_options('301')[0]['count'],2)

    def test_snapshot_and_reorder_preserve_candidates_without_reparse(self):
        data,a,s=indexes('[桜田明] 星空物語 1','[桜田 明] 星空物語 2','[Team (桜田明 / Missing)] 星空物語 3')
        with tempfile.TemporaryDirectory() as root:
            cache=RelatedDiskCache(Path(root),'synthetic','not-a-real-secret')
            self.assertTrue(cache.save(data,a,s))
            reverse=list(reversed(data))
            with patch('authors.parse_credit',side_effect=AssertionError('reparse')),patch('series.parse_series_title',side_effect=AssertionError('reparse')):
                aa,ss=cache.load(reverse)
            for b in data:
                old=s.relaxed_options(b['id']);new=ss.relaxed_options(b['id'])
                self.assertEqual(old,new)
                for option in old:
                    self.assertEqual(ss.relaxed_details(b['id'],option['id'])[1],tuple(reversed(s.relaxed_details(b['id'],option['id'])[1])))


class RelaxedHTTP(unittest.TestCase):
    setUp=fixtures.RelatedHTTPTests.setUp
    tearDown=fixtures.RelatedHTTPTests.tearDown
    publish=fixtures.RelatedHTTPTests.publish
    file=fixtures.RelatedHTTPTests.file
    server=fixtures.RelatedHTTPTests.server
    request=fixtures.RelatedHTTPTests.request

    def test_credit_source_notes_negotiation_and_authentication(self):
        self.books=books('[Alice] Nightstar 1','[Group (Alice / Missing)] Nightstar 2')
        self.books[1]['directory']='2-synthetic-credit'
        self.revision='f'*64;self.publish();before=list(self.db.iterdump())
        with self.server() as server:
            path='/v1/books/2/authors'
            self.assertEqual(json.loads(self.request(server,path+'?evidence=3')[2])['options'],[])
            choice=json.loads(self.request(server,path+'?evidence=3&credit=1')[2])['options'][0]
            result=path+'/'+choice['id']+'?evidence=3&credit=1&limit=50'
            status,headers,raw=self.request(server,result);self.assertEqual(status,200)
            self.assertEqual(json.loads(raw)['matchNotes'],{'2':'creditName'})
            self.assertEqual(self.request(server,result,headers['ETag'])[0],304)
            self.assertEqual(self.request(server,result,auth=False)[0],401)
            for suffix in ('credit=1','evidence=3&credit=','evidence=3&credit=2','evidence=3&credit=1&credit=1',
                           'relaxed=1','evidence=3&relaxed=','evidence=3&relaxed=2','evidence=3&relaxed=1&relaxed=1'):
                self.assertEqual(self.request(server,path+'?'+suffix)[0],400,suffix)
            self.assertEqual(self.request(server,'/v1/books/2/series?evidence=3&credit=1')[0],400)
        self.assertEqual(list(self.db.iterdump()),before)

    def test_joint_pagination_legacy_exclusion_and_original_order(self):
        self.books=books(*(f'[{"Hana-ko" if i%2 else "Hanako"}] Nightstar {i+1}' for i in range(102)))
        self.revision='d'*64;self.publish()
        with self.server() as server:
            path='/v1/books/1/series'
            old=json.loads(self.request(server,path+'?evidence=3')[2])['options'][0]
            new=json.loads(self.request(server,path+'?evidence=3&relaxed=1')[2])['options'][0]
            self.assertEqual(old['count'],51);self.assertEqual(new['count'],102)
            for size,offset,count in ((50,50,50),(500,0,102),(50,20000,2)):
                status,_,raw=self.request(server,path+'/'+new['id']+f'?evidence=3&relaxed=1&limit={size}&offset={offset}')
                self.assertEqual(status,200);result=json.loads(raw)
                rows=result['catalog']['books'];self.assertEqual(len(rows),count)
                self.assertEqual([b['rank'] for b in rows],sorted(b['rank'] for b in rows))
                self.assertEqual(set(result['matchNotes']),set(result['possibleBookIDs']))
                self.assertEqual(set(result['matchNotes'].values()),{'authorSeries'})


if __name__=='__main__':unittest.main()
