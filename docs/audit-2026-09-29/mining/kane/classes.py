# Manual classification of every NON-MERGE commit (197). Codes:
#  FIX    bug fix that changed source AND (in the same commit) a vitest/test file  -> "fix (tested)"
#  FIXn   bug fix with no test change (no suite yet / UI / CSS / build config / infra)  -> "fix (untested)"
#  FEAT   new capability / enhancement / feature-bundle
#  REF    refactor / extraction / restructure / perf memoization (behaviour-preserving intent)
#  DOC    docs only
#  CHORE  build / CI / config / scaffolding / dep upgrade / revert / repo hygiene
#  TEST   test-only (or tests + trivial harness)
#  REL    release / version bump
C = {}
def add(code, *shas):
    for s in shas: C[s]=code
add('FEAT','9197d72','8588388','9d51c1b','d01002b','75a338c','ee873ee','120ffd3','b434a63','a3887ee','a845e05','43fed6e','79e11e7','7997147',
    '1b05208','8b5e2fd','1e57017','6d3e2f6','7d39eb8','c22ee87','431b7c7','dc1d884','6f39edf','7a2db73','8e2f530','203e97a','f2936f4','66859dc',
    '4b9e1e4','55bf20e','6c86f99','7e901c5','d1d26b6','73cebda','cdf2c8e','92ae05b','48fa57b','9b713cf','ec29dd5','28fcac0','e5ea229','b442c4a',
    '057dbfc','99da0d1','b65dfa4','ca331a3','628b412','7b8d36c','46356f9','09879a0','2945ca8','1452ad6','29ff779','e341dd6','441a58c','8f0b735',
    '923fe78','7b69512','9484bd3','a0a12cb',
    # signal engine rework, one archetype/qualifier/phase per commit (feature slices with a sibling test)
    '86a4a3b','25a64d5','13f67aa','d14b198','9125a2d','ff63348','f8d5584','eb226bf','f61cf16','03f319a','ee56263','7afda2b','46abea3','ea37769',
    'c3aa7f2','eee25b4','a835732','b327c04','f5ed3ba','44d1c33','8995322','6a00653','887b16f','95dc140','20c2717','152f806','3e3b476','1ad3479','add5c8b')
add('FIX','4029a94','6b04fcb','6ab2d52','0e9b703','8f4555b','0fbf452','4203726','5837c59','f6bc7d7','db6c1cb','731e985','e0ef290','a9d8c9c','e952198',
    '271636f','ca2fdae','2289326')
add('FIXn','b74f99f','699a831','fbedf99','e6e0b11','fb144e4','ba71645','cc4b66f','2c5f6f0','34f8084','8490d93','4b48348','80a4ac1','bfac042',
     'cff2ce1','cc7a2e1','74bc289','befc629','7d17640','183b72f','209d7f0','d9369b0')
add('REF','00c2061','dbe752f','057dbfc_','2c92392','3abb57f','89e43fb','ee0d155','a0c1a95','6f164e1','a09337c','359a2e0','cf2d0e5','4361144','f24e28d')
add('DOC','2b329ee','498cd59','f89a5ce','0ffb193','688c3b2','896722e','af3675b','91286bd','bfae869','f7d9bc1','224dcf3','e5ed3d8','984c71d','2285f5a',
    'f43ca98','1c71c2e','0780c8a','241cbdf','64888f6','c4a3336','5e4603c','580481e','f7b62b1','985ee44','f593b23')
add('CHORE','0f3549a','b3f789c','641fc1e','834c76d','1b65dbf','1ef130d','11c89ca','5a749a2','1b9164a','dfaf285','a946909','d0dfa62','a6f4b02','b2dd55a')
add('TEST','edf548d','6d51667','0a0f284','aa0fe64','b90a322')
add('REL','eef0a37','f1dea71','e4ed550','0e6c954','5ed58fd','3ac0492','184aac7','0fdf166','44569fd','b56bbef','1594391','0ad7df5','48a1557','5b60290','ca331a3_')
C.pop('057dbfc_',None); C.pop('ca331a3_',None)
# corrections after reading messages
C['057dbfc']='REF'          # "Precompute card relationships into a shared, queryable layer"
C['ca331a3']='FEAT'         # perf/response-size (1.7.1) but a behavioural feature in the API
C['dbe752f']='FEAT'         # cache + unify colour identity rule
