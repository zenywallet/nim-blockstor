# Copyright (c) 2022 zenywallet

import macros

type
  HandleObj*[T] = object of RootObj
    handle*: T

template `.`*[T](handleObj: HandleObj[T]; field: untyped): untyped =
  handleObj.handle.field

template `.=`*[T](handleObj: HandleObj[T]; field, value: untyped) =
  handleObj.handle.field = value

macro returnToLastParam*(theProc: untyped): untyped =
  result = theProc
  var n: NimNode = result[3][0]
  if n.kind == nnkIdent or n.kind == nnkBracketExpr:
    if result[6].kind == nnkEmpty:
      result[6] = nnkStmtList.newTree(
        nnkAsgn.newTree(
          newIdentNode("result"),
          nnkCall.newTree(
            theProc.name
          )
        )
      )
      for i in 1..<result[3].len:
        for j in 0..<result[3][i].len - 2:
          if result[3][i][j].kind == nnkIdent:
            result[6][0][1].add(result[3][i][j])
    else:
      var findResultAsgn = false
      for n in result[6]:
        if n.kind == nnkAsgn and n[0].kind == nnkIdent and $n[0] == "result":
          findResultAsgn = true
          break
      if not findResultAsgn:
        let lastStmtPos = result[6].len - 1
        result[6][lastStmtPos] = nnkAsgn.newTree(
          newIdentNode("result"),
          result[6][lastStmtPos]
        )

      var returnSearch = true
      while returnSearch:
        returnSearch = false
        for i, n in result[6]:
          if n.kind == nnkReturnStmt and n[0].kind != nnkEmpty:
            returnSearch = true
            result[6].insert(i, nnkAsgn.newTree(
              newIdentNode("result"),
              result[6][i][0]
            ))
            result[6][i + 1] = nnkReturnStmt.newTree(
              newEmptyNode()
            )
            break

    result[3].add(nnkIdentDefs.newTree(
      newIdentNode("result"),
      nnkVarTy.newTree(n),
      newEmptyNode()
    ))
    result[3][0] = newEmptyNode()

macro returnToHandle*(theProc: untyped): untyped =
  result = theProc
  var n: NimNode
  let resultLen = result[3][0].len
  if resultLen > 0:
    n = result[3][0][resultLen - 1]
  else:
    n = result[3][0]
  if n.kind == nnkIdent:
    if result[6].kind == nnkEmpty:
      result[6] = nnkStmtList.newTree(
        nnkVarSection.newTree(
          nnkIdentDefs.newTree(
            newIdentNode("ret"),
            newEmptyNode(),
            nnkCall.newTree(
              theProc.name
            )
          )
        ),
        nnkAsgn.newTree(
          newIdentNode("result"),
          nnkDotExpr.newTree(
            newIdentNode("ret"),
            newIdentNode("handle")
          )
        ),
        nnkAsgn.newTree(
          nnkDotExpr.newTree(
            newIdentNode("ret"),
            newIdentNode("handle")
          ),
          newNilLit()
        )
      )
      for i in 1..<result[3].len:
        for j in 0..<result[3][i].len - 2:
          if result[3][i][j].kind == nnkIdent:
            result[6][0][0][2].add(result[3][i][j])

    result[0] = newIdentNode($theProc.name & "_returnToHandle")
    result[3][0] = newIdentNode("auto")
