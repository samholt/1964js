###1964js - JavaScript/HTML5 port of 1964 - N64 emulator
Copyright (C) 2012 Joel Middendorf

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.###
#jslint todo: true, bitwise: true

#globals window, mat4, C1964jsRenderer, consts, dec2hex, Float32Array
C1964jsVideoHLE = (core, glx) ->
  "use strict"

  @processDisplayList = @callBind @processDisplayList, this

  i = undefined
  @core = core #only needed for gfxHelpers prototypes to access.
  @gl = glx

  @fogIsImplemented = false #enable this when we supoort fog

  #todo: make gRSP a class object.
  @RICE_MATRIX_STACK = 60
  @MAX_TEXTURES = 8
  @MAX_VERTICES = 80
  @MAX_TILES = 8
  @tmem = new Uint8Array(1024 * 4)
  @activeTile = 0
  @textureTile = []
  @zDepthImage = {fmt: 0, siz: 0, width: 0, addr: 0}
  @zColorImage = {fmt: 0, siz: 0, width: 0, addr: 0}
  @N64VertexList = []
  @vtxTransformed = []
  @vtxNonTransformed = []
  @vecProjected = []
  @vtxProjected5 = []
  @geometryMode = 0
  @gRSP = {}
  @gRSPlights = [{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}]
  @gRSPn64lights = [{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}]
  @gRSPnumLights = 0
  @matToLoad = mat4.create()
  @lightingMat = mat4.create()
  @gRSPworldProject = mat4.create()
  @triangleVertexPositionBuffer = `undefined`
  @triangleVertexColorBuffer = `undefined`
  @dlistStackPointer = 0
  @dlistStack = []
  @renderer = new C1964jsRenderer(@core.settings, @core.webGL.gl, @core.webGL)
  @texImg = {}
  @segments = []
  @gl.useProgram @core.webGL.shaderProgram
  @primColor = [0.0, 0.0, 0.0, 0.0]
  @fillColor = [0.0, 0.0, 0.0, 0.0]
  @blendColor = [0.0, 0.0, 0.0, 0.0]
  @envColor = [0.0, 0.0, 0.0, 0.0]
  @triVertices = new Float32Array(16384)
  @triColorVertices = new Uint8Array(16384)
  @triTextureCoords = new Float32Array(16384)

  @tempVec4 = new Float32Array 4
  @tempVec3 = new Float32Array 3

  @otherModeL = 0
  @otherModeH = 0
  @cycleType = 0
  @alphaTestEnabled = 0
  @bShade = false
  @bTextureGen = false
  @bLightingEnable = false
  @bFogEnable = false
  @bZBufferEnable = false
  @colorsTexture0 = @gl.createTexture()
  @colorsTexture1 = @gl.createTexture()
  @renderStateChanged = false

  @normalMat = new Float32Array(4)
  @transformed = mat4.create()
  @nonTransformed = mat4.create()
  @modelViewInverse = mat4.create()
  @modelViewTransposedInverse = mat4.create()

  # Native Viewport
  @n64ViewportWidth = 640
  @n64ViewportHeight = 480
  @n64ViewportLeft = 0
  @n64ViewportTop = 0
  @n64ViewportRight = 320
  @n64ViewportBottom = 240


  #todo: different microcodes support
  @currentMicrocodeMap = @microcodeMap0
  i = 0
  while i < @MAX_TILES
    @textureTile[i] = []
    i += 1
  i = 0
  while i < @MAX_VERTICES
    @N64VertexList[i] = {}
    i += 1
  i = 0
  while i < consts.MAX_DL_STACK_SIZE
    @dlistStack[i] = {}
    i += 1
  i = 0
  while i < @segments.length
    @segments[i] = 0
    i += 1
  @gRSP.projectionMtxs = []
  @gRSP.modelviewMtxs = []
  @gRSP.ambientLightIndex = 0
  @gRSP.ambientLightColor = 0
  @gRSP.fAmbientLightA = 0
  @gRSP.fAmbientLightR = 0
  @gRSP.fAmbientLightG = 0
  @gRSP.fAmbientLightB = 0

  @gl.clearColor 0.0, 0.0, 0.0, 0.0
  @gl.depthFunc @gl.LEQUAL
  @gl.clearDepth 1.0
  @gl.disable @gl.DEPTH_TEST

  #todo: allocate on-demand
  i = 0
  while i < @RICE_MATRIX_STACK
    @gRSP.projectionMtxs[i] = mat4.create()
    @gRSP.modelviewMtxs[i] = mat4.create()
    i += 1
  @gRSP.vertexMult = 10
  @triangleVertexTextureCoordBuffer = `undefined`
  @resetMatrices()
  @combine = new Uint32Array(16)

  return this

(->
  "use strict"

  C1964jsVideoHLE::callBind = (fn, me) ->
    ->
      fn.call me

  C1964jsVideoHLE::processDisplayList = ->
    if @core.showFB is true
      @initBuffers()
      @core.webGL.show3D()
      @core.showFB = false
      @resetState()

    @core.webGL.beginDList()
    @dlParserProcess()

    #this.core.interrupts.triggerDPInterrupt(0, false);
    @core.interrupts.delayNextInterrupt = true #don't process immediately
    @core.interrupts.triggerDPInterrupt 0, false
    return

  C1964jsVideoHLE::videoLog = (msg) ->
    #console.log msg
    return

  C1964jsVideoHLE::dlParserProcess = ->
    @dlistStackPointer = 0
    @dlistStack[@dlistStackPointer].pc = (@core.memory.spMemUint8Array[consts.TASK_DATA_PTR] << 24 | @core.memory.spMemUint8Array[consts.TASK_DATA_PTR + 1] << 16 | @core.memory.spMemUint8Array[consts.TASK_DATA_PTR + 2] << 8 | @core.memory.spMemUint8Array[consts.TASK_DATA_PTR + 3])>>>0
    @dlistStack[@dlistStackPointer].countdown = consts.MAX_DL_COUNT

    #see RSP_Parser.cpp
    #TODO: purge old textures
    #TODO: stats
    #TODO: force screen clear
    #TODO: set vi scales
    @renderReset()

    #TODO: render reset
    #TODO: begin rendering
    #TODO: set viewport
    #TODO: set fill mode
    while @dlistStackPointer >= 0
      pc = @dlistStack[@dlistStackPointer].pc
      cmd = @getCommand(pc)
      func = @currentMicrocodeMap[cmd]
      @dlistStack[@dlistStackPointer].pc += 8
      this[func] pc
      if @dlistStackPointer >= 0
        @dlistStack[@dlistStackPointer].countdown -= 1
        @dlistStackPointer -= 1  if @dlistStack[@dlistStackPointer].countdown < 0
    return

  #TODO: end rendering
  C1964jsVideoHLE::RDP_GFX_PopDL = ->
    @dlistStackPointer -= 1
    return

  C1964jsVideoHLE::RSP_RDP_Nothing = (pc) ->
    #@videoLog "RSP RDP NOTHING"
    #@dlistStackPointer -= 1
    return

  C1964jsVideoHLE::RSP_GBI1_MoveMem = (pc) ->
    addr = undefined
    length = undefined
    type = @getGbi1Type(pc)
    seg = @getGbi0DlistAddr(pc)
    addr = @getRspSegmentAddr(seg)
    switch type
      when consts.RSP_GBI1_MV_MEM_VIEWPORT
        @RSP_MoveMemViewport addr
      #case RSP_GBI1_MV_MEM_LOOKATY:
      #break;
      #case RSP_GBI1_MV_MEM_LOOKATX:
      #break;
      when consts.RSP_GBI1_MV_MEM_L0, consts.RSP_GBI1_MV_MEM_L1, consts.RSP_GBI1_MV_MEM_L2, consts.RSP_GBI1_MV_MEM_L3, consts.RSP_GBI1_MV_MEM_L4, consts.RSP_GBI1_MV_MEM_L5, consts.RSP_GBI1_MV_MEM_L6, consts.RSP_GBI1_MV_MEM_L7
        dwLight = (type-consts.RSP_GBI1_MV_MEM_L0)/2
        @RSP_MoveMemLight dwLight, addr, pc
      when consts.RSP_GBI1_MV_MEM_MATRIX1
        @RSP_GFX_Force_Matrix pc
    return

  C1964jsVideoHLE::RSP_GFX_Force_Matrix = (pc) ->
    @RSP_GBI0_Mtx pc

  C1964jsVideoHLE::RSP_MoveMemViewport = (addr) ->
    @videoLog "RSP_MoveMemViewport"

    if addr + 16 >= @core.currentRdramSize
      console.warn "viewport addresses beyond mem size"
      return

    scale = new Float32Array(4)
    trans = new Float32Array(4)

    scale[0] = @getShort addr+0*2
    scale[1] = @getShort addr+1*2
    scale[2] = @getShort addr+2*2
    scale[3] = @getShort addr+3*2

    trans[0] = @getShort addr+4*2
    trans[1] = @getShort addr+5*2
    trans[2] = @getShort addr+6*2
    trans[3] = @getShort addr+7*2

    centerX = trans[0] / 4.0
    centerY = trans[1] / 4.0
    @n64ViewportWidth = scale[0] / 4.0
    @n64ViewportHeight = scale[1] / 4.0

    @n64ViewportWidth = -@n64ViewportWidth if @n64ViewportWidth < 0
    @n64ViewportHeight = -@n64ViewportHeight if @n64ViewportHeight < 0
    @n64ViewportLeft = centerX - @n64ViewportWidth
    @n64ViewportTop = centerY - @n64ViewportHeight
    @n64ViewportRight = centerX + @n64ViewportWidth
    @n64ViewportBottom = centerY + @n64ViewportHeight

    maxZ = 0x3FF

    #@setViewPort left, top, right, bottom, maxZ

    return

  C1964jsVideoHLE::RSP_GBI1_SpNoop = (pc) ->
    #@videoLog "RSP_GBI1_SpNoop"
    return

  C1964jsVideoHLE::RSP_GBI1_Reserved = (pc) ->
    #@videoLog "RSP_GBI1_Reserved"
    return

  C1964jsVideoHLE::setProjection = (mat, bPush, bReplace) ->
    if bPush is true
      if @gRSP.projectionMtxTop >= (@RICE_MATRIX_STACK - 1)
        @gRSP.bMatrixIsUpdated = true
        return
      @gRSP.projectionMtxTop += 1
      # We should store the current projection matrix...
      if bReplace
        # Load projection matrix
        mat4.set mat, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
      else
        mat4.multiply @gRSP.projectionMtxs[@gRSP.projectionMtxTop - 1], mat, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
    else
      if bReplace
        # Load projection matrix
        mat4.set mat, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
      else
        mat4.multiply @gRSP.projectionMtxs[@gRSP.projectionMtxTop], mat, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
    @gRSP.bMatrixIsUpdated = true

    #hack to show Mario's head (as an ortho projection. This if/else is wrong.
    if @gRSP.projectionMtxs[@gRSP.projectionMtxTop][14] > 0
      mat4.ortho -1024, 1024, -1024, 1024, -1023.0, 1024.0, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
    else
      mat4.ortho -1, 1, -1, 1, -1, 1, 1.0, 1024.0, this.gRSP.projectionMtxs[this.gRSP.projectionMtxTop]
    return

  C1964jsVideoHLE::setWorldView = (mat, bPush, bReplace) ->
    if bPush is true
      if @gRSP.modelViewMtxTop >= (@RICE_MATRIX_STACK - 1)
        @gRSP.bMatrixIsUpdated = true
        return
      @gRSP.modelViewMtxTop += 1
      if bReplace
        # Load modelView matrix
        mat4.set mat, @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
      else # Multiply modelView matrix
        mat4.multiply @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop - 1], mat, @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
    else # NoPush
      if bReplace
        # Load modelView matrix
        mat4.set mat, @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
      else
        # Multiply modelView matrix
        mat4.multiply @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop], mat, @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
    @gRSP.bMatrixIsUpdated = true
    return

  C1964jsVideoHLE::RSP_GBI0_Mtx = (pc) ->
    addr = undefined
    seg = @getGbi0DlistAddr(pc)
    addr = @getRspSegmentAddr(seg)
    #@videoLog "RSP_GBI0_Mtx addr: " + dec2hex(addr)
    @loadMatrix addr
    if @gbi0isProjectionMatrix pc
      @setProjection @matToLoad, @gbi0PushMatrix(pc), @gbi0LoadMatrix(pc)
    else
      @setWorldView @matToLoad, @gbi0PushMatrix(pc), @gbi0LoadMatrix(pc)

    @renderStateChanged = true
    return

  C1964jsVideoHLE::loadMatrix = (addr) ->
    #  todo: port and probably log warning message if true
    if (addr + 64 > @core.currentRdramSize)
      console.warn "loading matrix beyond ram size"
      return
    i = undefined
    j = undefined
    lo = undefined
    hi = undefined
    a = undefined
    k = 0
    i = 0
    while i < 4
      j = 0
      while j < 4
        a = addr + (i << 3) + (j << 1)
        hi = (@core.memory.rdramUint8Array[a] << 8 | @core.memory.rdramUint8Array[a + 1]) & 0x0000FFFF
        lo = (@core.memory.rdramUint8Array[a + 32] << 8 | @core.memory.rdramUint8Array[a + 32 + 1]) & 0x0000FFFF
        @matToLoad[k] = (((hi << 16) | lo)>>0) / 65536.0
        k += 1
        j += 1
      i += 1
    return

  #tile info.
  C1964jsVideoHLE::DLParser_SetTImg = (pc) ->
    @texImg.format = @getTImgFormat(pc)
    @texImg.size = @getTImgSize(pc)
    @texImg.width = @getTImgWidth(pc) + 1
    @texImg.addr = @getTImgAddr(pc)
    @texImg.bpl = @texImg.width << @texImg.size >> 1
    @texImg.changed = true #no texture cache
    #console.log "SetTImg: Format:"+ @texImg.format + " Size:" + @texImg.size + " Width: "+ @texImg.width
    return

  #this.videoLog('Texture: format=' + this.texImg.format + ' size=' + this.texImg.size + ' ' + 'width=' + this.texImg.width + ' addr=' + this.texImg.addr + ' bpl=' + this.texImg.bpl);

  C1964jsVideoHLE::RSP_GBI0_Vtx = (pc) ->
    v0 = undefined
    seg = undefined
    addr = undefined
    num = @getGbi0NumVertices(pc) + 1
    v0 = @getGbi0Vertex0(pc)
    seg = @getGbi0DlistAddr(pc)
    addr = @getRspSegmentAddr(seg)
    num = 32 - v0  if (v0 + num) > @MAX_VERTICES

    #Check that the address is valid
    if (addr + num*16) > @core.currentRdramSize
      console.warn "vertex is beyond ram size"
    else
      @processVertexData addr, v0, num
    return

  C1964jsVideoHLE::updateCombinedMatrix = ->
    return #this is set in the shader
    if @gRSP.bMatrixIsUpdated
      pmtx = undefined
      vmtx = @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
      pmtx = @gRSP.projectionMtxs[@gRSP.projectionMtxTop]
      mat4.multiply pmtx, vmtx, @gRSPworldProject

      #this.gRSPworldProject = this.gRSP.modelviewMtxs[this.gRSP.modelViewMtxTop] * this.gRSP.projectionMtxs[this.gRSP.projectionMtxTop];
      @gRSP.bMatrixIsUpdated = false
    return

  C1964jsVideoHLE::processVertexData = (addr, v0, num) ->
    a = undefined
    @updateCombinedMatrix()
    i = v0

    texWidth = ((@textureTile[@activeTile].lrs >> 2) + 1) - @textureTile[@activeTile].uls
    texHeight = ((@textureTile[@activeTile].lrt >> 2) + 1) - @textureTile[@activeTile].ult


    if @bLightingEnable is true
      mat4.inverse @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop], @modelViewInverse
      mat4.transpose @modelViewInverse, @modelViewTransposedInverse

    while i < v0 + num
      a = addr + 16 * (i - v0)

      @N64VertexList[i].w = @getVertexW(a)
      if @N64VertexList[i].w is 0
        @N64VertexList[i].w = 1.0
      @N64VertexList[i].x = @getVertexX(a)
      @N64VertexList[i].y = @getVertexY(a)
      @N64VertexList[i].z = @getVertexZ(a)

      @N64VertexList[i].u = @getVertexS(a) / 32 / texWidth
      @N64VertexList[i].v = @getVertexT(a) / 32 / texHeight



      if @bLightingEnable is true
        @normalMat[0] = @getVertexNormalX a
        @normalMat[1] = @getVertexNormalY a
        @normalMat[2] = @getVertexNormalZ a
        @normalMat[3] = 1.0

        mat4.multiplyVec4 @modelViewTransposedInverse, @normalMat, @tempVec4

        @tempVec3[0] = @tempVec4[0]
        @tempVec3[1] = @tempVec4[1]
        @tempVec3[2] = @tempVec4[2]
        vect = vec3.normalize @tempVec3

        # projectiontransposedInverse = mat4.create()
        # mat4.set @gRSP.projectionMtxs[@gRSP.projectionMtxTop], projectiontransposedInverse
        # mat4.transpose projectiontransposedInverse, projectiontransposedInverse
        # mat4.inverse projectiontransposedInverse, projectiontransposedInverse
        # mat4.multiply projectiontransposedInverse, @normalMat, @normalMat

        vertColor = @lightVertex vect
        @N64VertexList[i].r = vertColor[0]
        @N64VertexList[i].g = vertColor[1]
        @N64VertexList[i].b = vertColor[2]
        @N64VertexList[i].a = vertColor[3]
      else if @bShade is false
        @N64VertexList[i].r = @primColor[0]
        @N64VertexList[i].g = @primColor[1]
        @N64VertexList[i].b = @primColor[2]
        @N64VertexList[i].a = @primColor[3]
      else
        @N64VertexList[i].r = @getVertexColorR(a)
        @N64VertexList[i].g = @getVertexColorG(a)
        @N64VertexList[i].b = @getVertexColorB(a)
        @N64VertexList[i].a = @getVertexAlpha(a)

      #until we use it..
      #@N64VertexList[i].nx = (@toSByte @getVertexNormalX(a))
      #@N64VertexList[i].ny = (@toSByte @getVertexNormalY(a))
      #@N64VertexList[i].nz = (@toSByte @getVertexNormalZ(a))

      #console.log "Vertex "+i+": XYZ("+@N64VertexList[i].x+" , "+@N64VertexList[i].y+" , "+@N64VertexList[i].z+") ST("+@N64VertexList[i].s+" , "+@N64VertexList[i].t+") RGBA("+@N64VertexList[i].r+" , "+@N64VertexList[i].g+" , "+@N64VertexList[i].b+" , "+@N64VertexList[i].a+") N("+@N64VertexList[i].nx+" , "+@N64VertexList[i].ny+" , "+@N64VertexList[i].nz+")"
      i += 1
    return

  C1964jsVideoHLE::DLParser_SetCImg = (pc) ->
    @zColorImage.fmt = @getSetTileFmt pc
    @zColorImage.siz = @getSetTileSiz pc
    @zColorImage.width = @getTImgWidth(pc) + 1
    seg = @getGbi0DlistAddr(pc)
    @zColorImage.addr = @getRspSegmentAddr seg
    return

  C1964jsVideoHLE::DLParser_SetZImg = (pc) ->
    @zDepthImage.fmt = @getSetTileFmt pc
    @zDepthImage.siz = @getSetTileSiz pc
    @zDepthImage.width = @getTImgWidth(pc) + 1
    seg = @getGbi0DlistAddr(pc)
    @zDepthImage.addr = @getRspSegmentAddr seg
    return

  #Gets new display list address
  C1964jsVideoHLE::RSP_GBI0_DL = (pc) ->
    param = undefined
    seg = @getGbi0DlistAddr(pc)
    addr = @getRspSegmentAddr(seg)
    #@videoLog "dlist address = " + dec2hex(addr)

    #TODO: address adjust
    param = @getGbi0DlistParam(pc)
    @dlistStackPointer += 1  if param is consts.RSP_DLIST_PUSH
    @dlistStack[@dlistStackPointer].pc = addr
    @dlistStack[@dlistStackPointer].countdown = consts.MAX_DL_COUNT
    return

  C1964jsVideoHLE::DLParser_SetCombine = (pc) ->
    @combine[0] = @getCombineA0(pc)
    @combine[2] = @getCombineB0(pc)
    @combine[4] = @getCombineC0(pc)
    @combine[6] = @getCombineD0(pc)
    # @combineA0 = 0xFF if @combineA0 is 15
    # @combineB0 = 0xFF if @combineB0 is 15
    # @combineC0 = 0xFF if @combineC0 is 31
    # @combineD0 = 0xFF if @combineD0 is 7
    @combine[1] = @getCombineA0a(pc)
    @combine[3] = @getCombineB0a(pc)
    @combine[5] = @getCombineC0a(pc)
    @combine[7] = @getCombineD0a(pc)
    # @combineA0a = 0xFF if @combineA0a is 7
    # @combineB0a = 0xFF if @combineB0a is 7
    # @combineC0a = 0xFF if @combineC0a is 7
    # @combineD0a = 0xFF if @combineD0a is 7
    @combine[8] = @getCombineA1(pc)
    @combine[10] = @getCombineB1(pc)
    @combine[12] = @getCombineC1(pc)
    @combine[14] = @getCombineD1(pc)
    # @combineA1 = 0xFF if @combineA1 is 15
    # @combineB1 = 0xFF if @combineB1 is 15
    # @combineC1 = 0xFF if @combineC1 is 31
    # @combineD1 = 0xFF if @combineD1 is 7
    @combine[9] = @getCombineA1a(pc)
    @combine[11] = @getCombineB1a(pc)
    @combine[13] = @getCombineC1a(pc)
    @combine[15] = @getCombineD1a(pc)
    # @combineA1a = 0xFF if @combineA1a is 7
    # @combineB1a = 0xFF if @combineB1a is 7
    # @combineC1a = 0xFF if @combineC1a is 7
    # @combineD1a = 0xFF if @combineD1a is 7

    w0 = @core.memory.rdramUint8Array[pc] << 24 | @core.memory.rdramUint8Array[pc + 1] << 16 | @core.memory.rdramUint8Array[pc + 2] << 8 | @core.memory.rdramUint8Array[pc + 3]
    w1 = @core.memory.rdramUint8Array[pc + 4] << 24 | @core.memory.rdramUint8Array[pc + 5] << 16 | @core.memory.rdramUint8Array[pc + 6] << 8 | @core.memory.rdramUint8Array[pc + 7]

    #if (@combineD0 == 4)
    #  console.log " a0:" + @combineA0 + " b0:" + @combineB0 + " c0:" + @combineC0 + " d0:" + @combineD0 + " a0a:" + @combineA0a + " b0a:" + @combineB0a + " c0a:" + @combineC0a + " d0a:" + @combineD0a + " a1:" + @combineA1 + " b1:" + @combineB1 + " c1:" + @combineC1 + " d1:" + @combineD1 + " a1a:" + @combineA1a + " b1a:" + @combineB1a + " c1a:" + @combineC1a + " d1a:" + @combineD1a

    #@videoLog "TODO: DLParser_SetCombine"
    @core.webGL.setCombineUniforms this, @core.webGL.shaderProgram
    return

  C1964jsVideoHLE::RSP_GBI1_MoveWord = (pc) ->
    #@videoLog "RSP_GBI1_MoveWord"
    switch @getGbi0MoveWordType(pc)
      when consts.RSP_MOVE_WORD_MATRIX
        @RSP_RDP_InsertMatrix()
      when consts.RSP_MOVE_WORD_SEGMENT
        dwBase = undefined
        dwSegment = (@getGbi0MoveWordOffset(pc) >> 2) & 0x0F
        dwBase = @getGbi0MoveWordValue(pc) & 0x00FFFFFF
        @segments[dwSegment] = dwBase
      when consts.RSP_MOVE_WORD_NUMLIGHT
        dwNumLights = (@getGbi0MoveWordValue(pc)<< 1 >>> 6)-1
        @gRSP.ambientLightIndex = dwNumLights
        @gRSPnumLights = dwNumLights
      when consts.RSP_MOVE_WORD_LIGHTCOL
        light = @getGbi0MoveWordOffset(pc) >>> 5
        field = @getGbi0MoveWordOffset(pc)>>>0 & 0x7
        if field is 0
          if light is @gRSP.ambientLightIndex
            @setAmbientLight @getGbi0MoveWordValue(pc)
          else
            @setLightCol light, @getGbi0MoveWordValue(pc)
    return

  C1964jsVideoHLE::setAmbientLight = (col) ->
    @gRSP.ambientLightColor = col
    r = (col >>> 24) & 0xff
    g = (col >>> 16) & 0xff
    b = (col >>> 8) & 0xff
    a = col & 0xff
    @gRSP.fAmbientLightR = r
    @gRSP.fAmbientLightG = g
    @gRSP.fAmbientLightB = b
    @gRSP.fAmbientLightA = a
    return

  C1964jsVideoHLE::setLightCol = (dwLight, dwCol) ->
    r = ((dwCol >>> 24) & 0xFF)
    g = ((dwCol >>> 16) & 0xFF)
    b = ((dwCol >>> 8) & 0xFF)
    a = ((dwCol >>> 0) & 0xFF)
    @gRSPlights[dwLight].r = r
    @gRSPlights[dwLight].g = g
    @gRSPlights[dwLight].b = b
    @gRSPlights[dwLight].a = a
    return

  C1964jsVideoHLE::setLightDirection = (dwLight, x, y, z) ->
    lightVec = new Float32Array(3)
    lightVec[0] = x
    lightVec[1] = y
    lightVec[2] = z
    lightVec = vec3.normalize(lightVec)

    @gRSPlights[dwLight].x = lightVec[0]
    @gRSPlights[dwLight].y = lightVec[1]
    @gRSPlights[dwLight].z = lightVec[2]
    return

  C1964jsVideoHLE::lightVertex = (norm) ->
    r = @gRSP.fAmbientLightR
    g = @gRSP.fAmbientLightG
    b = @gRSP.fAmbientLightB
    a = @gRSP.fAmbientLightA

    for l in [0...@gRSPnumLights]
      fCosT = norm[0]*@gRSPlights[l].x + norm[1]*@gRSPlights[l].y + norm[2]*@gRSPlights[l].z
      if fCosT > 0
        r += @gRSPlights[l].r * fCosT
        g += @gRSPlights[l].g * fCosT
        b += @gRSPlights[l].b * fCosT
        a += @gRSPlights[l].a * fCosT

    if r < 0.0
      r = 0.0
    if g < 0.0
      g = 0.0
    if b < 0.0
      b = 0.0
    if a < 0.0
      a = 0.0
    if r > 255.0
      r = 255.0
    if g > 255.0
      g = 255.0
    if b > 255.0
      b = 255.0
    if a > 255.0
      a = 255.0

    return [r, g, b, 255.0]

  C1964jsVideoHLE::RSP_MoveMemLight = (dwLight, dwAddr, pc) ->
    if dwLight >= 16
      return

    @gRSPn64lights[dwLight].dwRGBA = @getGbi0MoveWordValue(dwAddr)
    @gRSPn64lights[dwLight].dwRGBACopy = @getGbi0MoveWordValue(dwAddr+4)
    @gRSPn64lights[dwLight].x = @getVertexLightX dwAddr
    @gRSPn64lights[dwLight].y = @getVertexLightY dwAddr
    @gRSPn64lights[dwLight].z = @getVertexLightZ dwAddr

    # disabled in Rice's code.
    # /*
    # {
    #   // Normalize light
    #   double sum = (double)gRSPn64lights[dwLight].x * gRSPn64lights[dwLight].x;
    #   sum += (double)gRSPn64lights[dwLight].y * gRSPn64lights[dwLight].y;
    #   sum += (double)gRSPn64lights[dwLight].z * gRSPn64lights[dwLight].z;
    #   sum = sqrt(sum);
    #   sum = sum/128.0;
    #   gRSPn64lights[dwLight].x /= sum;
    #   gRSPn64lights[dwLight].y /= sum;
    #   gRSPn64lights[dwLight].z /= sum;
    # }
    # */

    # normalize light
    # sum = @gRSPn64lights[dwLight].x * @gRSPn64lights[dwLight].x
    # sum += @gRSPn64lights[dwLight].y * @gRSPn64lights[dwLight].y
    # sum += @gRSPn64lights[dwLight].z * @gRSPn64lights[dwLight].z
    # sum = Math.sqrt(sum)
    # sum = sum/128.0
    # @gRSPn64lights[dwLight].x /= sum
    # @gRSPn64lights[dwLight].y /= sum
    # @gRSPn64lights[dwLight].z /= sum

    if dwLight == @gRSP.ambientLightIndex
      dwCol = @gRSPn64lights[dwLight].dwRGBA
      @setAmbientLight dwCol
    else
      @setLightCol dwLight, @gRSPn64lights[dwLight].dwRGBA
      if @getGbi0MoveWordValue(dwAddr+4) is 0  # Direction is 0! // This sucks. Give it a better name
      else
        @setLightDirection dwLight, @gRSPn64lights[dwLight].x, @gRSPn64lights[dwLight].y, @gRSPn64lights[dwLight].z
    return

  C1964jsVideoHLE::renderReset = ->

    #UpdateClipRectangle();
    #@resetMatrices()
    @gRSP.projectionMtxTop = 0
    @gRSP.modelViewMtxTop = 0


    #SetZBias(0);
    @gRSP.numVertices = 0
    @gRSP.curTile = 0
    @gRSP.fTexScaleX = 1 / 32.0
    @gRSP.fTexScaleY = 1 / 32.0

    @gl.clearDepth 1.0
    @gl.depthMask true
    @gl.clear @gl.DEPTH_BUFFER_BIT

    return

  C1964jsVideoHLE::resetMatrices = ->
    @gRSP.projectionMtxTop = 0
    @gRSP.modelViewMtxTop = 0
    mat4.identity @gRSP.modelviewMtxs[0]
    mat4.identity @gRSP.projectionMtxs[0]

    i = 0;
    while (i < @RICE_MATRIX_STACK)
      mat4.identity @gRSP.projectionMtxs[i]
      mat4.identity @gRSP.modelviewMtxs[i]
      i += 1

    @gRSP.bMatrixIsUpdated = false
    @updateCombinedMatrix()
    return

  C1964jsVideoHLE::RSP_RDP_InsertMatrix = ->
    @videoLog "TODO: Insert Matrix"
    @updateCombinedMatrix()
    @gRSP.bMatrixIsUpdated = false
    return

  C1964jsVideoHLE::DLParser_SetScissor = (pc) ->
    @videoLog "TODO: DLParser_SetScissor"
    return

  C1964jsVideoHLE::RSP_GBI1_SetOtherModeH = (pc) ->
    word0 = @getOtherModeH pc
    length = (word0 >>> 0) & 0xFF
    shift = (word0 >>> 8) & 0xFF
    mask = ((1<<length)-1)<<shift
    @otherModeH &= ~mask
    @otherModeH |= @getOtherModeH pc+4
    #alert @otherModeH
    @renderStateChanged = true
    return

  C1964jsVideoHLE::RSP_GBI1_SetOtherModeL = (pc) ->
    word0 = @getOtherModeL pc
    length = (word0 >>> 0) & 0xFF
    shift = (word0 >>> 8) & 0xFF
    mask = ((1<<length)-1)<<shift
    @otherModeL &= ~mask
    @otherModeL |= @getOtherModeL pc+4
    #alert dec2hex @otherModeL
    @DLParser_RDPSetOtherModeL(@otherModel)
    @renderStateChanged = true
    return

  C1964jsVideoHLE::RSP_GBI0_Sprite2DBase = (pc) ->
    @videoLog "TODO: RSP_GBI0_Sprite2DBase"
    return

  C1964jsVideoHLE::RSP_GBI0_Tri4 = (pc) ->
    @videoLog "TODO: RSP_GBI0_Tri4"
    return

  C1964jsVideoHLE::RSP_GBI1_RDPHalf_Cont = (pc) ->
    @videoLog "TODO: RSP_GBI1_RDPHalf_Cont"
    return

  C1964jsVideoHLE::RSP_GBI1_RDPHalf_2 = (pc) ->
    @videoLog "TODO: RSP_GBI1_RDPHalf_2"
    return

  C1964jsVideoHLE::RSP_GBI1_RDPHalf_1 = (pc) ->
    @videoLog "TODO: RSP_GBI1_RDPHalf_1"
    return

  C1964jsVideoHLE::RSP_GBI1_Line3D = (pc) ->
    @videoLog "TODO: RSP_GBI1_Line3D"
    return

  C1964jsVideoHLE::RSP_GBI1_ClearGeometryMode = (pc) ->
    data = @getClearGeometryMode(pc)>>>0
    @geometryMode &= ~data
    @initGeometryMode()
    @setDepthTest()
    return

  C1964jsVideoHLE::RSP_GBI1_SetGeometryMode = (pc) ->
    data = @getSetGeometryMode(pc)>>>0
    @geometryMode |= data
    @initGeometryMode()
    @setDepthTest()
    return

  C1964jsVideoHLE::initGeometryMode = () ->
    # cull face
    bCullFront = @geometryMode & consts.G_CULL_FRONT
    bCullBack = @geometryMode & consts.G_CULL_BACK
    if bCullBack isnt 0 and bCullFront isnt 0
      @gl.enable @gl.CULL_FACE
      @gl.cullFace @gl.FRONT_AND_BACK
    else if bCullBack isnt 0
      @gl.enable @gl.CULL_FACE
      @gl.cullFace @gl.BACK
    else if bCullFront isnt 0
      @gl.enable @gl.CULL_FACE
      @gl.cullFace @gl.FRONT
    else
      @gl.disable @gl.CULL_FACE

    if (@geometryMode & consts.G_SHADE) isnt 0
      @bShade = true
    else
      @bShade = false
    #this doesn't exist in WebGL, so find a replacement if
    #we need flat-shading.
    #bShadeSmooth = @geometryMode & consts.G_SHADING_SMOOTH
    #if bShade isnt 0 and bShadeSmooth isnt 0
    #  @gl.shadeModel @gl.SMOOTH
    #else
    #  @gl.shadeModel @gl.FLAT

    if (@geometryMode & consts.G_TEXTURE_GEN) isnt 0
      @bTextureGen = true
    else
      @bTexueGen = false
    if (@geometryMode & consts.G_LIGHTING) isnt 0
      @bLightingEnable = true
    else
      @bLightingEnable = false
    if (@geometryMode & consts.G_FOG) isnt 0
      @bFogEnable = true
    else
      @bFogEnable = false
    if (@geometryMode & consts.G_ZBUFFER) isnt 0
      @bZBufferEnable = true
    else
      @bZBufferEnable = false
    return


  C1964jsVideoHLE::RSP_GBI1_EndDL = (pc) ->
    @RDP_GFX_PopDL()
    @drawScene(false, @activeTile)
    #@resetState()
    return

  C1964jsVideoHLE::RSP_GBI1_Texture = (pc) ->
    tile = @getTextureTile(pc)
    @activeTile = tile
    @textureTile[tile].on    = @getTextureOn(pc)
    @textureTile[tile].level = @getTextureLevel(pc)
    @textureTile[tile].scales = @getTextureScaleS(pc) / 0x8000
    @textureTile[tile].scalet = @getTextureScaleT(pc) / 0x8000
    #console.log "RSP_GBI1_Texture: Tile:" + tile + " On:" + @textureTile[tile].on + " Level:" + @textureTile[tile].level + " ScaleS:" + @textureTile[tile].scales + " ScaleT:" + @textureTile[tile].scalet
    @drawScene false, tile
    return

  C1964jsVideoHLE::popProjection = () ->
    if @gRSP.projectionMtxTop > 0
      @gRSP.projectionMtxTop--
    return

  C1964jsVideoHLE::popWorldView = () ->
    if @gRSP.modelViewMtxTop > 0
      @gRSP.modelViewMtxTop--
      @gRSPmodelViewTop = @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]
      @gRSP.bMatrixIsUpdated = true
    return

  C1964jsVideoHLE::RSP_GBI1_PopMtx = (pc) ->
    if @gbi0PopMtxIsProjection pc
      @popProjection()
    else
      @popWorldView()
    @renderStateChanged = true
    return

  C1964jsVideoHLE::RSP_GBI1_CullDL = (pc) ->
    @videoLog "TODO: RSP_GBI1_CullDL"
    return

  C1964jsVideoHLE::RSP_GBI1_Tri1 = (pc) ->
    v0 = @getGbi0Tri1V0(pc) / @gRSP.vertexMult
    v1 = @getGbi0Tri1V1(pc) / @gRSP.vertexMult
    v2 = @getGbi0Tri1V2(pc) / @gRSP.vertexMult
    flag = @getGbi0Tri1Flag(pc)
    #console.log "Tri1: "+v0+", "+v1+", "+v2+"   Flag: "+flag
    didSucceed = @prepareTriangle v0, v1, v2

    if didSucceed is false
      return

    pc = @dlistStack[@dlistStackPointer].pc
    cmd = @getCommand(pc)
    func = @currentMicrocodeMap[cmd]
    if func is "RSP_GBI1_Tri1"
      return #loops until not tri1, then it will drawScene

    if @renderStateChanged is true
      @drawScene false, @activeTile
    return

  C1964jsVideoHLE::RSP_GBI1_Noop = (pc) ->
    #@videoLog "TODO: RSP_GBI1_Noop"
    return

  C1964jsVideoHLE::RDP_TriFill = (pc) ->
    @videoLog "TODO: RDP_TriFill"
    return

  C1964jsVideoHLE::RDP_TriFillZ = (pc) ->
    @videoLog "RDP_TriFillZ"
    return

  C1964jsVideoHLE::RDP_TriTxtr = (pc) ->
    @videoLog "TODO: RDP_TriTxtr"
    return

  C1964jsVideoHLE::RDP_TriTxtrZ = (pc) ->
    @videoLog "TODO: RDP_TriTxtrZ"
    return

  C1964jsVideoHLE::RDP_TriShade = (pc) ->
    @videoLog "TODO: RDP_TriShade"
    return

  C1964jsVideoHLE::RDP_TriShadeZ = (pc) ->
    @videoLog "TODO: RDP_TriShadeZ"
    return

  C1964jsVideoHLE::RDP_TriShadeTxtr = (pc) ->
    @videoLog "TODO: RDP_TriShadeTxtr"
    return

  C1964jsVideoHLE::RDP_TriShadeTxtrZ = (pc) ->
    @videoLog "TODO: RDP_TriShadeTxtrZ"
    return

  C1964jsVideoHLE::DLParser_TexRect = (pc, isFillRect) ->
    depthTestEnabled = true
    if depthTestEnabled
      #@setDepthTest()
      @gl.enable @gl.DEPTH_TEST
      @gl.depthFunc @gl.LEQUAL
    else
      @gl.disable @gl.DEPTH_TEST

    xh = @getTexRectXh(pc) >>> 2
    yh = @getTexRectYh(pc) >>> 2
    tileno = @getTexRectTileNo(pc)
    xl = @getTexRectXl(pc) >>> 2
    yl = @getTexRectYl(pc) >>> 2
    s = @getTexRectS(pc) >>> 5
    t = @getTexRectT(pc) >>> 5
    dsdx = @getTexRectDsDx(pc) >>> 10
    dtdy = @getTexRectDtDy(pc) >>> 10

    if @cycleType is consts.CYCLE_TYPE_COPY
      dsdx *= 0.25

    if @cycleType is consts.CYCLE_TYPE_FILL or @cycleType is consts.CYCLE_TYPE_COPY
      xh += 1.0
      yh += 1.0

    #console.log "Texrect: UL("+xl+","+yl+") LR("+xh+","+yh+") Tile:"+tileno+" TexCoord:("+s+","+t+") TexSlope:("+dsdx+","+dtdy+")"
    @renderer.texRect xl, yl, xh, yh, s, t, dsdx, dtdy, @textureTile[tileno], @tmem, this, isFillRect
    @hasTexture = true
    #@setDepthTest()
    #@drawScene false, 7
    return

  C1964jsVideoHLE::DLParser_TexRectFlip = (pc) ->
    @videoLog "TODO: DLParser_TexRectFlip"
    return

  C1964jsVideoHLE::DLParser_RDPLoadSynch = (pc) ->
    @renderStateChanged = true
    @videoLog "TODO: DLParser_RDPLoadSynch"
    return

  C1964jsVideoHLE::DLParser_RDPPipeSynch = (pc) ->
    @videoLog "TODO: DLParser_RDPPipeSynch"
    return

  C1964jsVideoHLE::DLParser_RDPTileSynch = (pc) ->
    @videoLog "TODO: DLParser_RDPTileSynch"
    return

  C1964jsVideoHLE::DLParser_RDPFullSynch = (pc) ->
    #@drawScene(7, false)
    return

  C1964jsVideoHLE::DLParser_SetKeyGB = (pc) ->
    @videoLog "TODO: DLParser_SetKeyGB"
    return

  C1964jsVideoHLE::DLParser_SetKeyR = (pc) ->
    @videoLog "TODO: DLParser_SetKeyR"
    return

  C1964jsVideoHLE::DLParser_SetConvert = (pc) ->
    @videoLog "TODO: DLParser_SetConvert"
    return

  C1964jsVideoHLE::DLParser_SetPrimDepth = (pc) ->
    @videoLog "TODO: DLParser_SetPrimDepth"
    return

  C1964jsVideoHLE::DLParser_RDPSetOtherModeL = (otherModeL) ->
    if (otherModeL & consts.RDP_ALPHA_COMPARE_THRESHOLD) isnt 0
      @alphaTestEnabled = 1
    else if (otherModeL & consts.RDP_ALPHA_COMPARE_DITHER) isnt 0
      @alphaTestEnabled = 1
    else
      @alphaTestEnabled = 0
    return

  C1964jsVideoHLE::DLParser_LoadTLut = (pc) ->
    @videoLog "TODO: DLParser_LoadTLut"
    return

  C1964jsVideoHLE::DLParser_SetTileSize = (pc) ->
    tile = @getSetTileSizeTile(pc)
    @textureTile[tile].uls = @getSetTileSizeUls(pc)
    @textureTile[tile].ult = @getSetTileSizeUlt(pc)
    @textureTile[tile].lrs = @getSetTileSizeLrs(pc)
    @textureTile[tile].lrt = @getSetTileSizeLrt(pc)
    #console.log "SetTileSize: UL("+@textureTile[tile].uls+"/"+@textureTile[tile].ult+") LR("+@textureTile[tile].lrs+"/"+@textureTile[tile].lrt+") Dim: "+@textureTile[tile].width+"x"+@textureTile[tile].height
    return

  C1964jsVideoHLE::DLParser_LoadBlock = (pc) ->
    tile = @getLoadBlockTile(pc)
    uls = @getLoadBlockUls(pc)
    ult = @getLoadBlockUlt(pc)
    lrs = @getLoadBlockLrs(pc)
    dxt = @getLoadBlockDxt(pc)
    #console.log "LoadBlock: Tile:"+tile+" UL("+uls+"/"+ult+") LRS:"+lrs+" DXT: 0x"+dec2hex(dxt)
    #textureAddr = @core.memory.rdramUint8Array[@texImg.addr])
    bytesToXfer = (lrs+1) * @textureTile[tile].siz
    if bytesToXfer > 4096
      console.error "LoadBlock is making too large of a transfer. "+bytesToXfer+" bytes"
    i=0
    while i < bytesToXfer
      @tmem[i]= @core.memory.rdramUint8Array[@texImg.addr+i]
      i++
    return

  C1964jsVideoHLE::DLParser_LoadTile = (pc) ->
    @videoLog "TODO: DLParser_LoadTile"
    return

  C1964jsVideoHLE::DLParser_SetTile = (pc) ->
    tile = @getSetTileTile(pc)
    @textureTile[tile].fmt = @getSetTileFmt(pc);
    @textureTile[tile].siz = @getSetTileSiz(pc);
    @textureTile[tile].line = @getSetTileLine(pc);
    @textureTile[tile].tmem = @getSetTileTmem(pc);
    @textureTile[tile].pal = @getSetTilePal(pc);
    @textureTile[tile].cmt = @getSetTileCmt(pc);
    @textureTile[tile].cms = @getSetTileCms(pc);
    @textureTile[tile].mirrorS = @getSetTileMirrorS(pc);
    @textureTile[tile].mirrorT = @getSetTileMirrorT(pc);
    @textureTile[tile].maskt = @getSetTileMaskt(pc);
    @textureTile[tile].masks = @getSetTileMasks(pc);
    @textureTile[tile].shiftt = @getSetTileShiftt(pc);
    @textureTile[tile].shifts = @getSetTileShifts(pc);
    #if @combineD0 == 4
    #console.log "SetTile:"+tile+" FMT:"+@textureTile[tile].fmt+" SIZ:"+@textureTile[tile].siz+" LINE: "+@textureTile[tile].line+" TMEM:"+@textureTile[tile].tmem+" PAL:"+@textureTile[tile].pal+" CMS/T:"+@textureTile[tile].cms+"/"+@textureTile[tile].cmt+" MASKS/T:"+@textureTile[tile].masks+"/"+@textureTile[tile].maskt+" SHIFTS/T:"+@textureTile[tile].shifts+"/"+@textureTile[tile].shiftt
    return

  C1964jsVideoHLE::DLParser_FillRect = (pc) ->
    # if @zDepthImage.addr isnt undefined and (@zDepthImage.addr is @zColorImage.addr)
    #   @gl.clearDepth 1.0
    #   @gl.depthMask true
    #   @gl.clear @gl.DEPTH_BUFFER_BIT
      #@gl.clearColor @fillColor[0], @fillColor[1], @fillColor[2], 1.0
      #@gl.clear @gl.COLOR_BUFFER_BIT
      #@gl.clearColor 0.0, 0.0, 0.0, 0.0
      #return

    @DLParser_TexRect pc, true

    # if @fillColor isnt undefined
    #   if @zDepthImage.addr isnt @zColorImage.addr
    #     @gl.clearColor 1.0, @fillColor[1], @fillColor[2], 1.0
    #     @gl.clear @gl.COLOR_BUFFER_BIT

    return

  C1964jsVideoHLE::DLParser_SetFillColor = (pc) ->
    @fillColor = []
    @fillColor.push @getSetFillColorR(pc)/255.0
    @fillColor.push @getSetFillColorG(pc)/255.0
    @fillColor.push @getSetFillColorB(pc)/255.0
    @fillColor.push @getSetFillColorA(pc)/255.0
    @gl.uniform4fv @core.webGL.shaderProgram.uFillColor, @fillColor
    return

  C1964jsVideoHLE::DLParser_SetFogColor = (pc) ->
    @videoLog "TODO: DLParser_SetFogColor"
    return

  C1964jsVideoHLE::DLParser_SetBlendColor = (pc) ->
    @blendColor = []
    @blendColor.push @getSetFillColorR(pc)/255.0
    @blendColor.push @getSetFillColorG(pc)/255.0
    @blendColor.push @getSetFillColorB(pc)/255.0
    @blendColor.push @getSetFillColorA(pc)/255.0
    @gl.uniform4fv @core.webGL.shaderProgram.uBlendColor, @blendColor
    return

  C1964jsVideoHLE::DLParser_SetPrimColor = (pc) ->
    @primColor = []
    @primColor.push @getSetPrimColorR(pc)/255.0
    @primColor.push @getSetPrimColorG(pc)/255.0
    @primColor.push @getSetPrimColorB(pc)/255.0
    @primColor.push @getSetPrimColorA(pc)/255.0
    #alert @primColor
    @gl.uniform4fv @core.webGL.shaderProgram.uPrimColor, @primColor
    return

  C1964jsVideoHLE::DLParser_SetEnvColor = (pc) ->
    @envColor = []
    @envColor.push @getSetEnvColorR(pc)/255.0
    @envColor.push @getSetEnvColorG(pc)/255.0
    @envColor.push @getSetEnvColorB(pc)/255.0
    @envColor.push @getSetEnvColorA(pc)/255.0
    @gl.uniform4fv @core.webGL.shaderProgram.uEnvColor, @envColor
    return

  C1964jsVideoHLE::prepareTriangle = (dwV0, dwV1, dwV2) ->
    #SP_Timing(SP_Each_Triangle);
    didSucceed = undefined #(CRender::g_pRender->IsTextureEnabled() || this.gRSP.ucode == 6 );
    textureFlag = false
    didSucceed = @initVertex(dwV0, @gRSP.numVertices, textureFlag)
    didSucceed = @initVertex(dwV1, @gRSP.numVertices + 1, textureFlag)  if didSucceed
    didSucceed = @initVertex(dwV2, @gRSP.numVertices + 2, textureFlag)  if didSucceed
    @gRSP.numVertices += 3  if didSucceed
    didSucceed

  C1964jsVideoHLE::initVertex = (dwV, vtxIndex, bTexture) ->
    #console.log "Vertex Index: "+vtxIndex+" dwV:"+dwV
    return false  if dwV >= consts.MAX_VERTS

    offset = 4 * @triangleVertexPositionBuffer.numItems++ # postfix addition is intentional for performance
    vertex = @N64VertexList[dwV]

    @triVertices[offset] = vertex.x
    @triVertices[offset+1] = vertex.y
    @triVertices[offset+2] = vertex.z
    @triVertices[offset+3] = vertex.w
    @triVertices[offset+3] = 1.0 if vertex.w == 0

    colorOffset = @triangleVertexColorBuffer.numItems++ << 2 # postfix addition is intentional for performance
    @triColorVertices[colorOffset]     = vertex.r
    @triColorVertices[colorOffset + 1] = vertex.g
    @triColorVertices[colorOffset + 2] = vertex.b
    @triColorVertices[colorOffset + 3] = vertex.a

    texOffset = @triangleVertexTextureCoordBuffer.numItems++ << 1 # postfix addition is intentional for performance
    @triTextureCoords[texOffset]     = vertex.u
    @triTextureCoords[texOffset + 1] = vertex.v
    true

  C1964jsVideoHLE::setBlendFunc = () ->
    CYCLE_TYPE_1 = 0
    CYCLE_TYPE_2 = 1
    CYCLE_TYPE_COPY = 2
    CYCLE_TYPE_FILL = 3
    CVG_DST_CLAMP = 0
    CVG_DST_WRAP = 0x100
    CVG_DST_FULL = 0x200
    CVG_DST_SAVE = 0x300
    BLEND_NOOP = 0x0000
    BLEND_NOOP5 = 0xcc48
    BLEND_NOOP4 = 0xcc08
    BLEND_FOG_ASHADE = 0xc800
    BLEND_FOG_3 = 0xc000
    BLEND_FOG_MEM = 0xc440
    BLEND_FOG_APRIM = 0xc400
    BLEND_BLENDCOLOR = 0x8c88
    BLEND_BI_AFOG = 0x8400
    BLEND_BI_AIN = 0x8040
    BLEND_MEM = 0x4c40
    BLEND_FOG_MEM_3 = 0x44c0
    BLEND_NOOP3 = 0x0c48
    BLEND_PASS = 0x0c08
    BLEND_FOG_MEM_IN_MEM = 0x0440
    BLEND_FOG_MEM_FOG_MEM = 0x04c0
    BLEND_OPA = 0x0044
    BLEND_XLU = 0x0040
    BLEND_MEM_ALPHA_IN = 0x4044

    blendMode1 = @otherModeL >>> 16 & 0xCCCC
    blendMode2 = @otherModeL >>> 16 & 0x3333
    @cycleType = @otherModeH >> 20 & 0x3

    switch @cycleType
      when CYCLE_TYPE_FILL
        @gl.disable @gl.BLEND
      when CYCLE_TYPE_COPY
        #this is wrong, but better for now. Hud has no alpha.
        # We should be calculating alpha transparency at the bottom of this function
        @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
        @gl.enable @gl.BLEND
      when CYCLE_TYPE_2
        forceBl = @otherModeL >> 14 & 0x1
        zCmp = @otherModeL >> 4 & 0x1
        alphaCvgSel = @otherModeL >> 13 & 0x1
        cvgXAlpha = @otherModeL >> 12 & 0x1

        if forceBl is 1 and zCmp is 1
          @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
          @gl.enable @gl.BLEND
        # else if alphaCvgSel is 1 && cvgXAlpha is 0
        #   @gl.blendFunc @gl.ONE, @gl.ZERO
        #   @gl.enable @gl.BLEND
        else switch blendMode1+blendMode2
          when (BLEND_PASS+(BLEND_PASS>>2)), (BLEND_FOG_APRIM+(BLEND_PASS>>2))
            @gl.blendFunc @gl.ONE, @gl.ZERO
            @gl.enable @gl.blendFunc
            if @cvgXAlpha is 1
              @gl.blendFunc @gl.ALPHA, @gl.ONE_MINUS_SRC_ALPHA
    #       if( gRDP.otherMode.alpha_cvg_sel )
    #       {
    #         Enable();
    #       }
    #       else
    #       {
    #         Enable();
    #       }
    #       break;
          when BLEND_PASS+(BLEND_OPA>>2)
            if cvgXAlpha is 1 and alphaCvgSel is 1
              @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
              @gl.enable @gl.BLEND
            else
              @gl.blendFunc @gl.ONE, @gl.ZERO
              @gl.enable @gl.BLEND
          when (BLEND_PASS + (BLEND_XLU>>2)), (BLEND_FOG_ASHADE + (BLEND_XLU>>2)), (BLEND_FOG_APRIM + (BLEND_XLU>>2)), (BLEND_FOG_MEM_FOG_MEM + (BLEND_PASS>>2)), (BLEND_XLU + (BLEND_XLU>>2)), (BLEND_BI_AFOG + (BLEND_XLU>>2)), (BLEND_XLU + (BLEND_FOG_MEM_IN_MEM>>2)), (BLEND_PASS + (BLEND_FOG_MEM_IN_MEM>>2))
            @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
            @gl.enable @gl.BLEND
          when BLEND_FOG_MEM_FOG_MEM + (BLEND_OPA>>2)
            if @fogIsImplemented
              @gl.blendFunc @gl.ONE, @gl.ZERO
              @gl.enable @gl.BLEND
            else
              @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
              @gl.enable @gl.BLEND

          when (BLEND_FOG_APRIM + (BLEND_OPA>>2)), (BLEND_FOG_ASHADE + (BLEND_OPA>>2)), (BLEND_BI_AFOG + (BLEND_OPA>>2)), (BLEND_FOG_ASHADE + (BLEND_NOOP>>2)), (BLEND_NOOP + (BLEND_OPA>>2)), (BLEND_NOOP4 + (BLEND_NOOP>>2)), (BLEND_FOG_ASHADE+(BLEND_PASS>>2)), (BLEND_FOG_3+(BLEND_PASS>>2))
            if @fogIsImplemented
              @gl.blendFunc @gl.ONE, @gl.ZERO
              @gl.enable @gl.BLEND
            else
              @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
              @gl.enable @gl.BLEND

          when BLEND_FOG_ASHADE+0x0301
            @gl.blendFunc @gl.SRC_ALPHA, @gl.ZERO
            @gl.enable @gl.BLEND
          when 0x0c08+0x1111
            @gl.blendFunc @gl.ZERO, @gl.DEST_ALPHA
            @gl.enable @gl.BLEND
          else
            if blendMode2 == BLEND_PASS>>2
              @gl.blendFunc @gl.ONE, @g.ZERO
            else
              @gl.blendFunc  @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
            @gl.enable @gl.BLEND
      else  # 1/2 Cycle or Copy
        forceBl = @otherModeL >> 14 & 0x1
        zCmp = @otherModeL >> 4 & 0x1
        if forceBl is 1 and zCmp is 1 and blendMode1 isnt BLEND_FOG_ASHADE
          @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
          @gl.enable @gl.BLEND
    #    if( gRDP.otherMode.force_bl && options.enableHackForGames == HACK_FOR_COMMANDCONQUER )
    #    {
    #      BlendFunc(D3DBLEND_SRCALPHA, D3DBLEND_INVSRCALPHA);
    #      Enable();
    #      break;
    #    }
        else switch blendMode1
    #    //switch ( blendmode_2<<2 )
          when BLEND_XLU, BLEND_BI_AIN, BLEND_FOG_MEM, BLEND_FOG_MEM_IN_MEM, BLEND_BLENDCOLOR, 0x00c0
            @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
            @gl.enable @gl.BLEND
          when BLEND_MEM_ALPHA_IN
            @gl.blendFunc @gl.ZERO, @gl.DEST_ALPHA
            @gl.enable @gl.BLEND
          when BLEND_PASS
            alphaCvgSel = @otherModeL >> 13 & 0x1
            @gl.blendFunc @gl.ONE, @gl.ZERO
            if alphaCvgSel != 0
              @gl.enable @gl.BLEND
            else
              @gl.disable @gl.BLEND
          when BLEND_OPA
            HACK_FOR_MARIO_TENNIS = true
            if HACK_FOR_MARIO_TENNIS
              @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
            else
              @gl.blendFunc @gl.ONE, @gl.ZERO
            @gl.enable @gl.BLEND
          when BLEND_NOOP, BLEND_FOG_ASHADE, BLEND_FOG_MEM_3, BLEND_BI_AFOG
            @gl.blendFunc @gl.ONE, @gl.ZERO
            @gl.enable @gl.BLEND
          when BLEND_FOG_APRIM
            @gl.blendFunc @gl.ONE_MINUS_SRC_ALPHA, @gl.ZERO
            @gl.enable @gl.BLEND
          when BLEND_NOOP3, BLEND_NOOP5
            @gl.blendFunc @gl.ZERO, @gl.ONE
            @gl.enable @gl.BLEND
          when BLEND_MEM
            # WaveRace
            @gl.blendFunc @gl.ZERO, @gl.ONE
            @gl.blendEquation @gl.FUNC_ADD
            @gl.enable @gl.BLEND
          else
            @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
            @gl.blendEquation @gl.FUNC_ADD
            @gl.enable @gl.BLEND
            #render->SetAlphaTestEnable(TRUE);
    return

  C1964jsVideoHLE::setDepthTest = () ->
    zBufferMode = (@geometryMode & consts.G_ZBUFFER) isnt 0
    zCmp = (@otherModeL & consts.Z_COMPARE) isnt 0
    zUpd = (@otherModeL & consts.Z_UPDATE) isnt 0
    if ((zBufferMode and zCmp) or zUpd)
      @gl.enable @gl.DEPTH_TEST
    else
      @gl.disable @gl.DEPTH_TEST
    @gl.depthMask zUpd
    return

  C1964jsVideoHLE::drawScene = (useTexture, tileno) ->
    @setBlendFunc()
    @setDepthTest()

    @renderStateChanged = false

    if @triangleVertexPositionBuffer.numItems > 0
      @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexPositionBuffer
      @gl.bufferData @gl.ARRAY_BUFFER, @triVertices.subarray(0, @triangleVertexPositionBuffer.numItems*@triangleVertexPositionBuffer.itemSize), @gl.STATIC_DRAW
      @gl.enableVertexAttribArray @core.webGL.shaderProgram.vertexPositionAttribute
      @gl.vertexAttribPointer @core.webGL.shaderProgram.vertexPositionAttribute, @triangleVertexPositionBuffer.itemSize, @gl.FLOAT, false, 0, 0

    if @triangleVertexColorBuffer.numItems > 0
      @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexColorBuffer
      @gl.bufferData @gl.ARRAY_BUFFER, @triColorVertices.subarray(0, @triangleVertexColorBuffer.numItems*@triangleVertexColorBuffer.itemSize), @gl.STATIC_DRAW
      @gl.enableVertexAttribArray @core.webGL.shaderProgram.vertexColorAttribute
      @gl.vertexAttribPointer @core.webGL.shaderProgram.vertexColorAttribute, @triangleVertexColorBuffer.itemSize, @gl.UNSIGNED_BYTE, true, 0, 0

    if @triangleVertexTextureCoordBuffer.numItems > 0
      @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexTextureCoordBuffer
      @gl.bufferData @gl.ARRAY_BUFFER, @triTextureCoords.subarray(0, @triangleVertexTextureCoordBuffer.numItems*@triangleVertexTextureCoordBuffer.itemSize), @gl.STATIC_DRAW
      @gl.enableVertexAttribArray @core.webGL.shaderProgram.textureCoordAttribute
      @gl.vertexAttribPointer @core.webGL.shaderProgram.textureCoordAttribute, @triangleVertexTextureCoordBuffer.itemSize, @gl.FLOAT, false, 0, 0
      tile = @textureTile[tileno]
      tileWidth = ((tile.lrs >> 2) + 1) - tile.uls
      tileHeight = ((tile.lrt >> 2) + 1) - tile.ult
      textureData = @renderer.formatTexture(tile, @tmem, this)
      if textureData isnt undefined
        @gl.activeTexture(@gl.TEXTURE0)
        @gl.bindTexture(@gl.TEXTURE_2D, @colorsTexture0)
        wrapS = @gl.REPEAT
        wrapT = @gl.REPEAT
        if ((tile.cms is consts.RDP_TXT_CLAMP) or (tile.masks is 0))
          wrapS = @gl.CLAMP_TO_EDGE
        else if tile.cms is consts.RDP_TXT_MIRROR
          wrapS = @gl.MIRRORED_REPEAT
        if ((tile.cmt is consts.RDP_TXT_CLAMP) or (tile.maskt is 0))
          wrapT = @gl.CLAMP_TO_EDGE
        else if tile.cmt is consts.RDP_TXT_MIRROR
          wrapT = @gl.MIRRORED_REPEAT
        @gl.texParameteri(@gl.TEXTURE_2D, @gl.TEXTURE_WRAP_S, wrapS)
        @gl.texParameteri(@gl.TEXTURE_2D, @gl.TEXTURE_WRAP_T, wrapT)
        @gl.texParameteri(@gl.TEXTURE_2D, @gl.TEXTURE_MAG_FILTER, @gl.LINEAR)
        @gl.texParameteri(@gl.TEXTURE_2D, @gl.TEXTURE_MIN_FILTER, @gl.NEAREST)
        if textureData instanceof HTMLElement
          # it's a canvas element
          @gl.texImage2D(@gl.TEXTURE_2D, 0, @gl.RGBA, @gl.RGBA, @gl.UNSIGNED_BYTE, textureData)
        else
          @gl.texImage2D(@gl.TEXTURE_2D, 0, @gl.RGBA, tileWidth, tileHeight, 0, @gl.RGBA, @gl.UNSIGNED_BYTE, textureData)

    #@gl.uniform1i @core.webGL.shaderProgram.otherModeL, @otherModeL
    #@gl.uniform1i @core.webGL.shaderProgram.otherModeH, @otherModeH
    @gl.uniform1i @core.webGL.shaderProgram.cycleType, @cycleType
    @gl.uniform1i @core.webGL.shaderProgram.uAlphaTestEnabled, @alphaTestEnabled

    # Matrix Uniforms
    @gl.uniformMatrix4fv(@core.webGL.shaderProgram.pMatrixUniform, false, @gRSP.projectionMtxs[@gRSP.projectionMtxTop]);
    @gl.uniformMatrix4fv(@core.webGL.shaderProgram.mvMatrixUniform, false, @gRSP.modelviewMtxs[@gRSP.modelViewMtxTop]);

    if @triangleVertexPositionBuffer.numItems > 0
      if @core.settings.wireframe is true
        @gl.drawArrays @gl.LINES, 0, @triangleVertexPositionBuffer.numItems
      else
        @gl.drawArrays @gl.TRIANGLES, 0, @triangleVertexPositionBuffer.numItems

    @triangleVertexPositionBuffer.numItems = 0
    @triangleVertexColorBuffer.numItems = 0
    @triangleVertexTextureCoordBuffer.numItems = 0
    @gRSP.numVertices = 0
    return

  C1964jsVideoHLE::resetState = ->
    @geometryMode = 0
    @initGeometryMode()
    @alphaTestEnabled = 0
    @activeTile = 0
    return

  C1964jsVideoHLE::initBuffers = ->
    @triangleVertexPositionBuffer = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexPositionBuffer
    @triangleVertexPositionBuffer.itemSize = 4
    @triangleVertexPositionBuffer.numItems = 0

    @triangleVertexColorBuffer = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexColorBuffer
    @triangleVertexColorBuffer.itemSize = 4
    @triangleVertexColorBuffer.numItems = 0

    @triangleVertexTextureCoordBuffer = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, @triangleVertexTextureCoordBuffer
    @triangleVertexTextureCoordBuffer.itemSize = 2
    @triangleVertexTextureCoordBuffer.numItems = 0
    return
  return
)()
#hack global space until we export classes properly
#node.js uses exports; browser uses this (window)
root = exports ? this
root.C1964jsVideoHLE = C1964jsVideoHLE
