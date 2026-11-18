## 改动内容

<!-- 做了什么，为什么。关联的 issue 写成 Fixes #编号 -->

## 验证

- [ ] `cargo test --workspace --locked`
- [ ] `cargo clippy --workspace --all-targets --locked -- -D warnings`
- [ ] `bash scripts/swift-test.sh`
- [ ] 涉及界面、热键、权限、XPC 或更新时，已用 `bash scripts/build-app.sh` 构建并在正常桌面会话中手动验证
- [ ] 涉及查询或索引性能时，已运行 `bash scripts/regression.sh`

<!-- 手动验证的步骤与结果写在这里 -->

## 文档

- [ ] 查询语法变化已同步 `docs/SEARCH-GUIDE.md`
- [ ] 依赖变化已同步 `THIRD_PARTY_NOTICES.md`
- [ ] 面向用户的变化已写入 `CHANGELOG.md`
