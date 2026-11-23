# ملاحظات تكامل API-Football

- المضيف: `https://v3.football.api-sports.io/`
- الترويسة: `x-apisports-key: <SECRET>` وتُرسل من Cloudflare Worker فقط.
- المنطقة الزمنية المستخدمة في طلبات المباريات: `Asia/Aden`، أي توقيت اليمن UTC+3.
- مباريات يوم محدد: `/fixtures?date=YYYY-MM-DD&timezone=Asia/Aden`.
- المباريات المباشرة: `/fixtures?live=all&timezone=Asia/Aden`.
- أحداث المباراة: `/fixtures/events?fixture={fixture_id}`.
- التشكيلات: `/fixtures/lineups?fixture={fixture_id}`.
- إحصائيات المباراة: `/fixtures/statistics?fixture={fixture_id}`.
- ترتيب الدوري: `/standings?league={league_id}&season={year}`.
- الهدافون: `/players/topscorers?league={league_id}&season={year}`.
- صناع الأهداف: `/players/topassists?league={league_id}&season={year}`.
- معلومات اللاعب: `/players?id={player_id}&season={year}`.
- معلومات النادي ولاعبيه: `/teams?id={team_id}` و`/players?team={team_id}&season={year}`.
- انتقالات اللاعب: `/transfers?player={player_id}`.
- الدوريات: `/leagues?current=true`.

## اعتبارات الخطة المجانية

- الخطة المجانية التي أكدتها لوحة الحساب: 100 طلب يومياً، وبحد 10 طلبات في الدقيقة.
- لا يمكن استدعاء كل تفاصيل كل مباراة باستمرار بهذه الحصة. يعتمد التطبيق على Cloudflare KV cache لتقليل التكرار، مع مدد مختلفة للبيانات الأقل تغيراً.
- غياب بيانات التشكيلة أو الإحصائيات قد يعني أن البطولة لا توفر هذه التغطية، ولا يُنشئ التطبيق بيانات بديلة.
- شعارات الفرق والدوريات وصور اللاعبين تأتي من روابط الاستجابة التي يقدمها API-Football عند توفرها.
- لا يوفر API-Football بث فيديو للمباريات ولا موجز أخبار صحفية.
- لا تضع مفتاح API في Flutter أو GitHub أو داخل APK؛ خزّنه في Cloudflare Worker Secret باسم `API_FOOTBALL_KEY`.

راجع التغطية والأسعار الرسمية قبل الإطلاق؛ الحصص وشروط الخدمة يمكن أن تتغير.


## حواجز الاستهلاك والتشغيل

- التطبيق لا يطلب التحديث كل ثانية؛ تحديث القائمة يتم يدوياً أو عند فتح الشاشة، لتقليل الاستهلاك.
- Worker يفحص KV أولاً، ثم يحجز طلباً من عداد D1 مشترك قبل كل طلب خارجي إلى API-Football؛ السقف 90 طلباً خارجياً في اليوم بتوقيت UTC، مع ترك 10 طلبات من حصة الخطة المجانية كاحتياط.
- إذا بلغ العداد 90، يعيد Worker HTTP 429 ويوقف الطلب الخارجي حتى يوم جديد.
- API-FOOTBALL Free يحدد 100 طلب يومياً و10 طلبات في الدقيقة. ويذكر مزود الخدمة أن عناوين IP المشتركة في بعض بيئات Serverless، بما فيها Cloudflare Workers، قد تؤثر في حدود المعدل؛ ينبغي التحقق عملياً بعد النشر.
