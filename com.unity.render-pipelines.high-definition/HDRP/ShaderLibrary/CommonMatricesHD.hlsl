#ifdef UNITY_SHADER_VARIABLES_MATRIX_DEFS_LEGACY_UNITY_INCLUDED
    #error Mixing HDCamera and legacy Unity matrix definitions
#endif

#ifndef UNITY_COMMON_MATRICES_HD_INCLUDED
#define UNITY_COMMON_MATRICES_HD_INCLUDED

#if defined(USING_STEREO_MATRICES)

#define UNITY_MATRIX_M     unity_ObjectToWorld
#define UNITY_MATRIX_I_M   unity_WorldToObject
#define UNITY_MATRIX_V     _ViewMatrixStereo[unity_StereoEyeIndex]
#define UNITY_MATRIX_I_V   _InvViewMatrixStereo[unity_StereoEyeIndex]
#define UNITY_MATRIX_P     OptimizeProjectionMatrix(unity_StereoMatrixP[unity_StereoEyeIndex])
#define UNITY_MATRIX_I_P   _InvProjMatrixStereo[unity_StereoEyeIndex]
#define UNITY_MATRIX_VP    _ViewProjMatrixStereo[unity_StereoEyeIndex]
#define UNITY_MATRIX_I_VP  _InvViewProjMatrixStereo[unity_StereoEyeIndex]
#define UNITY_MATRIX_MV    mul(UNITY_MATRIX_V, UNITY_MATRIX_M)

#else

#define UNITY_MATRIX_M     unity_ObjectToWorld
#define UNITY_MATRIX_I_M   unity_WorldToObject
#define UNITY_MATRIX_V     _ViewMatrix
#define UNITY_MATRIX_I_V   _InvViewMatrix
#define UNITY_MATRIX_P     OptimizeProjectionMatrix(_ProjMatrix)
#define UNITY_MATRIX_I_P   _InvProjMatrix
#define UNITY_MATRIX_VP    _ViewProjMatrix
#define UNITY_MATRIX_I_VP  _InvViewProjMatrix
#define UNITY_MATRIX_MV    mul(UNITY_MATRIX_V, UNITY_MATRIX_M)

#endif // USING_STEREO_MATRICES

#endif // UNITY_COMMON_MATRICES_HD_INCLUDED