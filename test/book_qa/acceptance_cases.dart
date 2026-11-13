/// Human-checked questions for the synthetic 12-page textbook fixture.
///
/// The expected pages and answer points were checked by hand against
/// [bookPageTexts]; this is the Q01 regression set. A real Q09 acceptance still
/// needs the user's own textbook and a real DeepSeek account.
class AcceptanceCase {
  const AcceptanceCase({
    required this.question,
    required this.focusPage,
    required this.expectedPages,
    required this.expectedChapter,
    required this.answerPoint,
    this.needsExternal = false,
    this.category = 'definition',
  });

  final String question;
  final int focusPage;
  final Set<int> expectedPages;
  final String expectedChapter;
  final String answerPoint;
  final bool needsExternal;
  final String category;

  bool get startsOutsideExpectedPages => !expectedPages.contains(focusPage);
}

const acceptanceCases = <AcceptanceCase>[
  AcceptanceCase(
    question: '聚合物是什么？',
    focusPage: 12,
    expectedPages: {1, 2},
    expectedChapter: '第一章 聚合物基础',
    answerPoint: '许多重复单元通过共价键连接而成的大分子。',
  ),
  AcceptanceCase(
    question: '单体是什么？',
    focusPage: 5,
    expectedPages: {2},
    expectedChapter: '第一章 聚合物基础',
    answerPoint: '能形成聚合物重复单元的分子。',
  ),
  AcceptanceCase(
    question: '高分子材料的性能和什么有关？',
    focusPage: 1,
    expectedPages: {3, 12},
    expectedChapter: '第一章 聚合物基础',
    answerPoint: '与链结构密切相关，链结构和共聚组成共同决定性能。',
    category: 'crossChapter',
  ),
  AcceptanceCase(
    question: '链结构描述什么？',
    focusPage: 9,
    expectedPages: {4},
    expectedChapter: '第二章 链结构',
    answerPoint: '描述重复单元在聚合物链中的排列方式。',
  ),
  AcceptanceCase(
    question: '聚合物链有哪些连接方式？',
    focusPage: 12,
    expectedPages: {5},
    expectedChapter: '第二章 链结构',
    answerPoint: '头尾连接、头头连接和尾尾连接。',
  ),
  AcceptanceCase(
    question: '为什么聚合物多以头尾键连为主？',
    focusPage: 1,
    expectedPages: {5, 7, 8},
    expectedChapter: '第二章 链结构',
    answerPoint: '位阻和活性中心/过渡态电子稳定；具体选择性取决于单体和机理。',
    needsExternal: true,
    category: 'reason',
  ),
  AcceptanceCase(
    question: '头尾连接和头头连接有什么区别？',
    focusPage: 12,
    expectedPages: {5, 6},
    expectedChapter: '第二章 链结构',
    answerPoint: '连接方向不同，影响链规整性和材料性能。',
    category: 'relation',
  ),
  AcceptanceCase(
    question: '头尾键连为什么会更稳定？',
    focusPage: 3,
    expectedPages: {7, 8},
    expectedChapter: '第二章 链结构',
    answerPoint: '需要结合位阻与过渡态稳定解释，教材只给结论。',
    needsExternal: true,
    category: 'reason',
  ),
  AcceptanceCase(
    question: '影响连接方式比例的因素有哪些？',
    focusPage: 2,
    expectedPages: {8},
    expectedChapter: '第二章 链结构',
    answerPoint: '单体和聚合机理。',
    category: 'condition',
  ),
  AcceptanceCase(
    question: '共聚物是什么？',
    focusPage: 2,
    expectedPages: {9},
    expectedChapter: '第三章 共聚',
    answerPoint: '由两种或多种单体共同聚合而成。',
  ),
  AcceptanceCase(
    question: '竞聚率描述什么？',
    focusPage: 1,
    expectedPages: {10},
    expectedChapter: '第三章 共聚',
    answerPoint: '两种单体在共聚过程中的相对反应活性。',
  ),
  AcceptanceCase(
    question: '共聚组成会随什么变化？',
    focusPage: 12,
    expectedPages: {11},
    expectedChapter: '第三章 共聚',
    answerPoint: '随转化率变化，需区分瞬时组成与平均组成。',
    category: 'condition',
  ),
  AcceptanceCase(
    question: '链结构怎样影响材料性能？',
    focusPage: 12,
    expectedPages: {3, 6, 12},
    expectedChapter: '第二章 链结构',
    answerPoint: '链结构影响规整性，共聚组成共同决定性能。',
    needsExternal: true,
    category: 'crossChapter',
  ),
  AcceptanceCase(
    question: '共聚和链结构有什么联系？',
    focusPage: 1,
    expectedPages: {9, 12},
    expectedChapter: '第三章 共聚',
    answerPoint: '链结构与共聚组成共同决定材料性能。',
    category: 'crossChapter',
  ),
  AcceptanceCase(
    question: '作者有没有说过头尾连接是唯一方式？',
    focusPage: 8,
    expectedPages: {5, 7},
    expectedChapter: '第二章 链结构',
    answerPoint: '没有；书中列了三种连接方式，并说多以头尾为主。',
    category: 'author',
  ),
  AcceptanceCase(
    question: '有没有头尾连接的现实应用例子？',
    focusPage: 2,
    expectedPages: {5, 7},
    expectedChapter: '第二章 链结构',
    answerPoint: '教材没有给应用例子，需要外部资料补充并标注。',
    needsExternal: true,
    category: 'example',
  ),
  AcceptanceCase(
    question: '这个结论有什么例外？',
    focusPage: 6,
    expectedPages: {6, 7, 8},
    expectedChapter: '第二章 链结构',
    answerPoint: '教材只说“多以”且取决于单体和机理，不能当无例外定律。',
    needsExternal: true,
    category: 'exception',
  ),
  AcceptanceCase(
    question: '最新研究对头尾连接有什么补充？',
    focusPage: 12,
    expectedPages: {5, 7},
    expectedChapter: '第二章 链结构',
    answerPoint: '教材没有时效性数据，需要真实搜索并注明来源时间。',
    needsExternal: true,
    category: 'latest',
  ),
  AcceptanceCase(
    question: '第5页提到的连接方式在第7页怎么解释？',
    focusPage: 5,
    expectedPages: {5, 7},
    expectedChapter: '第二章 链结构',
    answerPoint: '第5页列连接方式，第7页给常见聚合中的结论。',
    category: 'crossPage',
  ),
  AcceptanceCase(
    question: '聚合物的重复单元和单体是什么关系？',
    focusPage: 9,
    expectedPages: {1, 2, 9},
    expectedChapter: '第一章 聚合物基础',
    answerPoint: '单体形成重复单元，重复单元构成聚合物。',
    category: 'crossChapter',
  ),
];
