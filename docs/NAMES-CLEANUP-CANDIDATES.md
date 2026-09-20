# Чистка имён исполнителей — кандидаты (черновик, 20.09.2026)

Пункт 5 предложений по «Моей музыке» (Alex TG 20132): навести порядок в именах один раз. **Ждёт ответа Alex «браться ли»** (вопрос задан в TG 20148–20151, 20.09.2026); ничего в базе не менялось.
Список собран только чтением копии базы ПК (7 657 песен, 3 757 «главных» имён исполнителя — как их видит телефон: всё до первого feat / запятой / «/»).

Две группы:
1. **Число в начале имени.** «01 Vengaboys», «04 Five», «09 Steps» — с нулём впереди это номер трека (безопасно чистить); без нуля бывает настоящее имя («2 Unlimited», «50 Cent», «3 Doors Down», «5 Seconds Of Summer», «4 Non Blondes»): автоматом НЕ чистить, только по списку. Если «чистый» двойник уже есть в базе («Robbie Williams» и «15 Robbie Williams») — почти наверняка номер.
2. **Разные написания одного имени** (регистр, дефис, пробел, точка, апостроф): «Dj Bobo / DJ Bobo», «E-Rotic / E Rotic», «'N Sync / 'NSync / N'sync». Осторожно: складывание убирает и дефисы, так что «Di-rect» и «Direct» окажутся вместе — нужен просмотр.

Развилка для Alex: (а) только склеивать в «Моей музыке» на телефоне (база не меняется, обратимо), (б) реально переименовать в базе (телефон получит переименования при синхронизации; перед правкой — бэкап базы, dry-run со списком «что на что», явное «да»).

Сырой вывод (`names_candidates.py` по `real_tracks.json` — выборка id/исполнитель/название из копии базы):

```
исполнителей (главных имён): 3757
--- число в начале: всего 47
  с нулём (01–09): 9 | есть «чистый» двойник: 12
  01 Vengaboys                       -> Vengaboys                        1  НОМЕР двойник-есть
  04 Five                            -> Five                             1  НОМЕР двойник-есть
  09 Steps                           -> Steps                            1  НОМЕР двойник-есть
  02 Dru Hill                        -> Dru Hill                         1  НОМЕР 
  03 Cardigans                       -> Cardigans                        1  НОМЕР 
  05 Tamperer                        -> Tamperer                         1  НОМЕР 
  06 E-Life                          -> E-Life                           1  НОМЕР 
  07 Hollis P. Monroe                -> Hollis P. Monroe                 1  НОМЕР 
  08 Janet                           -> Janet                            1  НОМЕР 
  10 Atb                             -> Atb                              1  двойник-есть
  11 Another Level                   -> Another Level                    1  двойник-есть
  13 Jessica                         -> Jessica                          1  двойник-есть
  14 Faithless                       -> Faithless                        1  двойник-есть
  15 Robbie Williams                 -> Robbie Williams                  1  двойник-есть
  16 E-Type                          -> E-Type                           1  двойник-есть
  17 Loona                           -> Loona                            1  двойник-есть
  19 Volumia!                        -> Volumia!                         1  двойник-есть
  4 Wings                            -> Wings                            1  двойник-есть
  12 Extince                         -> Extince                          1  
  18 X-Treme                         -> X-Treme                          1  
  2 Be Or Not 2 Be                   -> Be Or Not 2 Be                   1  
  2 Boys                             -> Boys                             1  
  2 Brothers On The 4 Floor          -> Brothers On The 4 Floor          3  
  2 Brothers On The 4Th Floor        -> Brothers On The 4Th Floor        2  
  2 Brothers On The 4th Floor        -> Brothers On The 4th Floor        1  
  2 Eivissa                          -> Eivissa                          6  
  2 For Good                         -> For Good                         1  
  2 For Love                         -> For Love                         1  
  2 Raff                             -> Raff                             1  
  2 Shy                              -> Shy                              1  
  2 Unlimited                        -> Unlimited                        9  
  20 Fingers                         -> Fingers                          1  
  3 Doors Down                       -> Doors Down                       2  
  3-O-Matic                          -> O-Matic                          1  
  4 Friends & Shary                  -> Friends & Shary                  1  
  4 Girlz                            -> Girlz                            1  
  4 Non Blondes                      -> Non Blondes                      1  
  4 Side                             -> Side                             1  
  4 The Cause                        -> The Cause                        1  
  5 Seconds Of Summer                -> Seconds Of Summer                8  
  5 Seconds of Summer                -> Seconds of Summer                1  
  50 Cent                            -> Cent                             3  
  740 Boys With. 2 In Room           -> Boys With. 2 In Room             1  
  740 Boyz                           -> Boyz                             1  
  75 Modd                            -> Modd                             1  
  84 King Street                     -> King Street                      1  
  89 Ers                             -> Ers                              1  
--- написания-двойники: групп 105 | строк-имён 227
  Rue du Soleil (24)  |  Rue Du Soleil (13)
  DAB (25)  |  Dab (3)
  Armin van Buuren (17)  |  Armin Van Buuren (7)
  Dj Bobo (21)  |  DJ Bobo (1)
  P!nk (18)  |  P!NK (4)
  Di-Rect (17)  |  Di-rect (3)  |  Direct (1)
  E-Rotic (14)  |  E Rotic (5)
  Dr. Alban (15)  |  Dr.Alban (1)
  E-Type (12)  |  E Type (3)
  Ilse DeLange (8)  |  Ilse Delange (5)  |  Ilse De Lange (1)
  Lady Gaga (12)  |  Lady GaGa (2)
  OneRepublic (9)  |  Onerepublic (3)  |  One Republic (1)
  Mr. President (11)  |  Mr.President (2)
  Ace Of Base (10)  |  Ace of Base (1)
  Gavin Degraw (6)  |  Gavin DeGraw (5)
  Jeroen Van Der Boom (7)  |  Jeroen van der Boom (4)
  VanVelzen (8)  |  Vanvelzen (2)
  In-Grid (7)  |  In Grid (1)  |  Ingrid (1)
  5 Seconds Of Summer (8)  |  5 Seconds of Summer (1)
  Ice MC (4)  |  Ice Mc (3)  |  Ice M.C (1)
  'N Sync (6)  |  'NSync (1)  |  N'sync (1)
  Atc (5)  |  ATC (3)
  De Jeugd Van Tegenwoordig (7)  |  De Jeugd van Tegenwoordig (1)
  Alejandro De Pinedo (5)  |  Alejandro de Pinedo (3)
  R. Kelly (6)  |  R Kelly (1)
  Flo Rida (5)  |  Flo-Rida (2)
  Hit'n'Hide (4)  |  Hit'n'hide (2)
  K-Otic (3)  |  K-otic (3)
  Mr Probz (3)  |  Mr. Probz (3)
  Axwell ^ Ingrosso (4)  |  Axwell & Ingrosso (1)  |  Axwell Ingrosso (1)
  X-Perience (3)  |  X Perience (2)
  Bomfunk Mc's (3)  |  Bomfunk MC's (1)  |  Bomfunk Mcs (1)
  Gigi D'Agostino (4)  |  Gigi Dagostino (1)
  John The Whistler (4)  |  John the whistler (1)
  Volumia! (4)  |  Volumia (1)
  DJ Jean (3)  |  Dj Jean (2)
  A-Teens (3)  |  A Teens (1)  |  A'Teens (1)
  D Note (2)  |  D'Note (1)  |  D´Note (1)  |  D’Note (1)
  Lil Kleine (4)  |  Lil' Kleine (1)
  Bg The Prince Of Rap (3)  |  B.G. The Prince Of Rap (1)
  N-Trance (3)  |  N Trance (1)
  Snap (2)  |  Snap! (2)
  Dj Mendez (3)  |  DJ Mendez (1)
  Melodie MC (2)  |  Melodie Mc (2)
  Elize (3)  |  EliZe (1)
  Sander Van Doorn (2)  |  Sander van Doorn (2)
  Jason Mraz (3)  |  Jason M'raz (1)
  Ke$ha (2)  |  Ke$Ha (1)  |  Keha (1)
  Will.I.Am (3)  |  Will.i.am (1)
  Mc Sar & Real Mccoy (2)  |  M.C. Sar & Real McCoy (1)  |  Mc Sar & Real McCoy (1)
  Zayn (2)  |  ZAYN (1)
  The Kid LAROI (2)  |  The Kid Laroi (1)
  Olivia Rodrigo (2)  |  olivia rodrigo (1)
  Sophie Ellis-Bextor (2)  |  Sophie Ellis Bextor (1)
  2 Brothers On The 4Th Floor (2)  |  2 Brothers On The 4th Floor (1)
  Zhi-Vago (2)  |  Zhivago (1)
  Th Express (2)  |  T.H. Express (1)
  Mark 'oh (2)  |  Mark'Oh (1)
  Paps 'N' Skar (1)  |  Paps 'n' Skar (1)  |  Paps'n'skar (1)
  Daddy Dj (2)  |  Daddy DJ (1)
  DJ Jurgen (2)  |  Dj Jurgen (1)
  Bløf (2)  |  BLØF (1)
  t.A.T.u (2)  |  T. A. T. U (1)
  Acda En De Munnik (1)  |  Acda en De Munnik (1)  |  Acda en de Munnik (1)
  OhmG & Bruno (2)  |  Ohm-G & Bruno (1)
  J.R. Haim (2)  |  J- R- Haim (1)
  K'naan (1)  |  Knaan (1)  |  KNaan (1)
  B.O.B (2)  |  Bob (1)
  Cee Lo Green (2)  |  Ceelo Green (1)
  O'G3NE (1)  |  O'G3ne (1)  |  Og3ne (1)
```
