# 地图朝向与路线校准设计

> - 状态：方案 B 已由用户确认，书面规格待审阅
> - 日期：2026-08-25
> - 范围：地图的 27 个地点、39 条规则连接及其原创可视化路径
> - 规则基线：[RULES.md](../../../RULES.md)

## 1. 目标

修正当前地图上下镜像与部分路线看似错误的问题，使 App 中的地点方位和连接关系与《Brass: Birmingham》实体棋盘一致，同时继续使用项目自己的背景、节点、路线和交互表现。

完成后：

- Warrington、Leek、Belper、Nottingham 位于地图上部；
- Worcester、Gloucester、Oxford 位于地图下部；
- 27 个地点和规则数据中的 39 条连接全部可见；
- `kidderminster-worcester` 的视觉端点是 Kidderminster 与 Worcester，沿线农场仍保留为规则相邻地点；
- Cannock 乡村酒桶位于 Cannock 西侧并以独立路线连接 Cannock；Kidderminster—Worcester 乡村酒桶位于该路线西侧，以短支线表达“与路线相邻”而不冒充端点；
- 需要绕开其他城市或减轻交叉的路线使用曲线，不再把每条连接强制画成两点直线；
- 地图上所有城市、商人地点和乡村酒桶使用完整中文名称，英文 slug 只作为内部稳定 ID；
- 点击命中区域、选中发光、路线标签和缩放后的 44 pt 最小触控尺寸继续有效。

## 2. 参考边界

坐标和连接关系通过以下资料交叉核对：

- Roxley `v2018.11` 英文规则书；
- 能完整看到实体棋盘的商品照片；
- 一份公开的非官方数字实现，用于独立核对地点相对位置和 39 条连接；
- 本项目 `GameData/v2018.11/map.json` 中已经验证的规则拓扑。

外部图片只用于开发期人工核对。官方地图、PDF、照片、图标、字体及其他美术不得加入 Assets、应用包或最终截图基线。`.superpowers/` 中的临时对照页不属于 App 资源。

## 3. 已确认的根因

### 3.1 纵向坐标系相反

`BoardPresentationCatalog.standard` 的归一化坐标按左上角为原点编排，数值较小表示靠近地图上部。`MapNodeFactory.point(for:in:)` 却直接把 `y` 乘以 SpriteKit 场景高度；SpriteKit 的原点在左下角，因此所有地点被纵向镜像。

修复方式是在唯一的坐标转换边界中执行 `sceneY = (1 - normalizedY) * height`。演示数据和展示目录继续保存便于阅读、与参考图一致的左上原点归一化坐标，其他调用者不各自翻转。

### 3.2 路线端点取值错误

规则路线同时包含：

- `endpoints`：视觉和铺设连接片的两个端点；
- `adjacentLocationIDs`：规则上与路线相邻的地点，允许额外包含一个农场啤酒厂。

当前 `BoardPresentationCatalog.routes(for:)` 使用 `adjacentLocationIDs.first` 与 `.last` 生成视觉路线。`kidderminster-worcester` 的相邻数组包含第三个农场，因而视觉路线被错误生成成 Kidderminster 到农场。

修复方式是只使用经过 `GameDataValidator` 验证、数量恒为 2 的 `route.endpoints` 生成 `MapRoute`。`adjacentLocationIDs` 继续仅供资源、网络和计分规则使用。

### 3.3 两点直线不足以表达棋盘路线

当前每条路线只有 `move` 和 `addLine`。即使拓扑端点正确，长距离连接也会穿过城市、标签或其他线路，产生“路线接错”的视觉效果。

修复方式是把规则拓扑与展示几何分开：规则数据仍只决定哪些地点相连，展示目录为每条路线提供零至两个归一化控制点。零个控制点画直线，一个控制点画二次曲线，两个控制点画三次曲线。

## 4. 组件设计

### 4.1 `BoardPresentationCatalog`

展示目录负责两类静态、原创的地图数据：

- 27 个地点的左上原点归一化坐标；
- 39 条路线的可选控制点。

新增一个轻量的 `MapRoutePresentation` 值类型，包含 `routeID`、零至两个 `MapNormalizedPoint` 控制点，以及可选的 `MapRouteSpur`。`MapRouteSpur` 只保存规则相邻农场的 `locationID` 和路线参数 `t`；二者都不进入规则 JSON、保存状态或网络协议。

`validate(board:)` 在现有地点覆盖检查之外，还必须检查：

- 展示路线 ID 无重复；
- 展示路线 ID 与规则路线 ID 完全相等；
- 每个控制点的 x、y 都在 `0...1`；
- 每条路线最多两个控制点；
- 支线 `t` 是有限数值且位于 `0...1`，支线地点必须是该规则路线中除两个端点之外的唯一 `adjacentLocationIDs`；
- 规则路线恰好有两个有效 `endpoints`。

### 4.2 `MapNodeFactory`

`point(for:in:)` 作为归一化坐标到 SpriteKit 场景坐标的唯一转换入口，统一翻转 y 轴。

新增纯函数，根据起点、终点和 `MapRoutePresentation` 生成 `CGPath`：

- 0 个控制点：`addLine`；
- 1 个控制点：`addQuadCurve`；
- 2 个控制点：`addCurve`。

可见路线与 44 pt 命中路线必须共享同一个主 `CGPath`，避免看得到却点不到。路线标签使用同一几何的中点；为避免引入通用曲线求长算法，中点按对应 Bézier 在 `t = 0.5` 计算，再沿用当前 18 scene-unit 的上移偏移。

若路线具有 `MapRouteSpur`，工厂从对应农场节点位置向主路线的 `point(at: t)` 生成一条较短的装饰支线。`GameMapScene` 把它作为与主路线并列、没有 `route:` 或 `location:` 名称的节点加入内容层，因此点击支线不会被误判成可铺设的第 40 条路线。支线只表达农场与主路线的规则关联，不创建额外 `MapRoute`，也不改变铺设连接片的两个端点。

### 4.3 `GameMapScene`

`configure` 从 `BoardPresentationCatalog.standard` 按 route ID 取得展示几何，并传给 `MapNodeFactory.routeNode`。找不到展示几何属于开发数据错误：验证测试必须提前失败；运行时仍以无控制点直线兜底，避免地图整个消失。

节点、路线的 name、zPosition、发光、所有者颜色、运河/铁路透明度和无障碍表示保持不变。

### 4.4 中文地点标签

`MapLocation.name` 继续承载用户可见的中文名称，地点 `id` 继续使用既有英文 slug。任何坐标、路线、保存状态、网络消息和规则查询只引用 `id`，不把中文文案当作键。

地点徽标必须显示完整中文名，不再使用当前的“四个字符加省略号”策略：

- 4 个汉字以内使用单行标准字号；
- 5 至 7 个汉字使用单行紧凑字号；
- 超过 7 个汉字使用最多两行，徽标高度随之增加；
- 商人地点和乡村酒桶遵循同一排版规则，但使用各自的形状或颜色语义；
- 缩放时徽标继续按屏幕点尺寸保持可读，不随地图缩成无法辨认的小字。

高亮路线标签也使用中文端点名称，并允许两行显示；其内部 `route:` name 仍使用英文路线 ID。VoiceOver 读取完整中文名称，而不是缩写或英文 slug。

## 5. 数据流

1. `map.json` 解码为 `GameCore.BoardDefinition`，提供规则地点、路线端点和规则相邻地点。
2. `BoardPresentationCatalog` 验证自己完整覆盖 27 个地点和 39 条路线。
3. `routes(for:)` 仅从 `route.endpoints` 创建 `MapRoute`。
4. 对局投影继续给 `MapRoute` 附加连接片所有者和时代信息。
5. `GameMapScene.configure` 合并实时对局状态与静态展示几何，并把可选农场支线作为不参与目标命中的装饰节点加入内容层。
6. `MapNodeFactory` 把左上原点归一化坐标转换为 SpriteKit 坐标，并生成共享的可见/命中曲线路径与独立装饰支线。

规则数据、对局状态和展示路径保持单向依赖；改动路线弯曲方式不会改变合法行动或计分。

## 6. 坐标与路径校准策略

以 900 × 850 的开发期参考网格重新标定地点，再归一化保存。完整地点范围包括 20 个城市、5 个商人地点和 2 个农场啤酒厂。

先校准四个边界锚点，再校准中心网络：

- 上边界：Warrington、Leek、Belper、Nottingham；
- 下边界：Worcester、Gloucester、Oxford；
- 左边界：Shrewsbury、Coalbrookdale；
- 右边界：Nottingham、Coventry、Oxford；
- 中心：Cannock、Wolverhampton、Walsall、Tamworth、Dudley、Birmingham、Nuneaton。

路线控制点只解决三类问题：绕开非端点城市、减少不必要交叉、贴合整体南北/东西走向。不会逐像素临摹实体棋盘，也不会为了装饰添加规则中不存在的连接。

### 6.1 两个乡村酒桶的明确位置和语义

- `cannock-farm`：放在 Cannock 左侧，与 Cannock 大致同一纵向层级。规则中 `cannock-cannock-farm` 的 endpoints 就是 Cannock 与该农场，因此它按普通路线绘制，农场是合法端点。
- `kidderminster-worcester-farm`：放在 Kidderminster—Worcester 走廊左侧，纵向位于两城之间。`kidderminster-worcester` 的 endpoints 仍是两座城市；农场只存在于 `adjacentLocationIDs`。主路线继续连接两城，另绘短支线把农场视觉关联到主路线中段。

两个农场继续作为可点击的 `MapLocation` 渲染并显示啤酒厂产业位；它们不使用城市标签样式，也不改变 27 个地点的总数。

## 7. 错误处理

- 规格数据错误由 `BoardPresentationCatalog.validate` 和单元测试在开发期阻断。
- 运行时若某路线缺少展示几何，使用端点直线兜底并保留交互，不触发崩溃。
- 若端点地点不在当前投影中，维持现有行为：跳过该路线节点；这只可能发生在不完整或损坏的对局投影中。
- 所有坐标必须为有限数值并位于 `0...1`，拒绝 NaN、无穷或越界控制点。

## 8. 测试设计

测试按失败—通过顺序实施：

1. 在 `BoardPresentationCatalogTests` 中先证明 `kidderminster-worcester` 当前使用了错误端点，再改为断言其端点集合恰好是 Kidderminster 和 Worcester。
2. 新增朝向测试：把 Stoke-on-Trent 与 Worcester 转换为场景点后，Stoke-on-Trent 的 scene y 必须更大。
3. 新增展示目录完整性测试：27 个地点、39 条路线，路线 ID 与规则定义完全一致，控制点合法。
4. 新增曲线路径测试：至少选择一条有控制点的路线，断言生成路径包含曲线元素且起止点对应规则端点。
5. 新增农场语义测试：Cannock 农场是 `cannock-cannock-farm` 的端点；南侧农场不是 `kidderminster-worcester` 的端点，但其展示支线地点与规则额外相邻地点一致。
6. 新增中文标签测试：可见标签不含省略号，长名称分成不超过两行，内部节点 name 仍使用英文 ID。
7. 更新路线命中测试，使用实际曲线在 `t = 0.5` 的点，而不是端点算术平均值。
8. 运行整个 `IndustrialCityBirminghamTests`，确保规则、交互、视口与命中区域没有回归。
9. 运行 `FriendsPlayableUITests/testRealFixtureLandscapeVisualEvidence`，导出新的横屏截图，与开发期参考图人工核对朝向、节点顺序、路线交叉、两个乡村酒桶的位置、中文名称完整性和文字遮挡。

## 9. 验收标准

- 自动测试全部通过；
- 横屏截图中上、下边界地点顺序正确；
- 27 个地点和 39 条路线均渲染；
- Kidderminster—Worcester 线路不以农场为终点；
- Cannock 乡村酒桶位于 Cannock 左侧并由独立路线连接；南侧乡村酒桶位于 Kidderminster—Worcester 走廊左侧并通过短支线关联主路线；
- 长线路不穿过明显无关的城市节点，中心区域主要路线可辨认；
- 路线和地点在最小/最大缩放下仍有至少 44 pt 的命中范围；
- 高亮、连接片所有者颜色和路线标签继续工作；
- 27 个地点显示完整中文名，长名称最多两行且没有省略号，VoiceOver 读出相同的完整中文名；
- App 资源目录中没有新增任何官方地图图片、PDF 或其他官方美术。

## 10. 非目标

- 不重绘或替换 `IndustrialMap` 原创背景；
- 不逐像素复制官方线路造型；
- 不改变规则拓扑、玩家人数过滤或网络/计分逻辑；
- 不在本次工作中处理地图以外的剩余手工验收项；
- 不加入在线图片请求或运行时外部依赖。
