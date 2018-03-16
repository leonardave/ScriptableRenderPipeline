#ifndef LIGHTWEIGHT_LIGHTING_INCLUDED
#define LIGHTWEIGHT_LIGHTING_INCLUDED

#include "CoreRP/ShaderLibrary/Common.hlsl"
#include "CoreRP/ShaderLibrary/EntityLighting.hlsl"
#include "CoreRP/ShaderLibrary/ImageBasedLighting.hlsl"
#include "LWRP/ShaderLibrary/Core.hlsl"
#include "LWRP/ShaderLibrary/Shadows.hlsl"

#ifdef NO_ADDITIONAL_LIGHTS
#undef _ADDITIONAL_LIGHTS
#endif

// If lightmap is not defined than we evaluate GI (ambient + probes) from SH
// We might do it fully or partially in vertex to save shader ALU
#if !defined(LIGHTMAP_ON)
    #ifdef SHADER_API_GLES
        // Evaluates SH fully in vertex
        #define EVALUATE_SH_VERTEX
    #else
        // Evaluates L2 SH in vertex and L0L1 in pixel
        #define EVALUATE_SH_MIXED
    #endif
#endif

#ifdef LIGHTMAP_ON
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT) OUT.xy = lightmapUV.xy * lightmapScaleOffset.xy + lightmapScaleOffset.zw;
    #define OUTPUT_SH(normalWS, OUT)
#else
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT)
    #define OUTPUT_SH(normalWS, OUT) OUT.xyz = SampleSHVertex(normalWS)
#endif

///////////////////////////////////////////////////////////////////////////////
//                          Light Helpers                                    //
///////////////////////////////////////////////////////////////////////////////

// Abstraction over Light input constants
struct LightInput
{
    float4  position;
    half3   color;
    half4   distanceAttenuation;
    half4   spotDirection;
    half4   spotAttenuation;
};

// Abstraction over Light shading data.
struct Light
{
    half3   direction;
    half3   color;
    half    attenuation;
    half    subtractiveModeAttenuation;
};

///////////////////////////////////////////////////////////////////////////////
//                        Attenuation Functions                               /
///////////////////////////////////////////////////////////////////////////////
half CookieAttenuation(float3 worldPos)
{
#ifdef _MAIN_LIGHT_COOKIE
#ifdef _MAIN_LIGHT_DIRECTIONAL
    float2 cookieUV = mul(_WorldToLight, float4(worldPos, 1.0)).xy;
    return SAMPLE_TEXTURE2D(_MainLightCookie, sampler_MainLightCookie, cookieUV).a;
#elif defined(_MAIN_LIGHT_SPOT)
    float4 projPos = mul(_WorldToLight, float4(worldPos, 1.0));
    float2 cookieUV = projPos.xy / projPos.w + 0.5;
    return SAMPLE_TEXTURE2D(_MainLightCookie, sampler_MainLightCookie, cookieUV).a;
#endif // POINT LIGHT cookie not supported
#endif

    return 1;
}

// Matches Unity Vanila attenuation
// Attenuation smoothly decreases to light range.
half DistanceAttenuation(half distanceSqr, half3 distanceAttenuation)
{
    // We use a shared distance attenuation for additional directional and puctual lights
    // for directional lights attenuation will be 1
    half quadFalloff = distanceAttenuation.x;
    half denom = distanceSqr * quadFalloff + 1.0;
    half lightAtten = 1.0 / denom;

    // We need to smoothly fade attenuation to light range. We start fading linearly at 80% of light range
    // Therefore:
    // fadeDistance = (0.8 * 0.8 * lightRangeSq)
    // smoothFactor = (lightRangeSqr - distanceSqr) / (lightRangeSqr - fadeDistance)
    // We can rewrite that to fit a MAD by doing
    // distanceSqr * (1.0 / (fadeDistanceSqr - lightRangeSqr)) + (-lightRangeSqr / (fadeDistanceSqr - lightRangeSqr)
    // distanceSqr *        distanceAttenuation.y            +             distanceAttenuation.z
    half smoothFactor = saturate(distanceSqr * distanceAttenuation.y + distanceAttenuation.z);
    return lightAtten * smoothFactor;
}

half SpotAttenuation(half3 spotDirection, half3 lightDirection, half4 spotAttenuation)
{
    // Spot Attenuation with a linear falloff can be defined as
    // (SdotL - cosOuterAngle) / (cosInnerAngle - cosOuterAngle)
    // This can be rewritten as
    // invAngleRange = 1.0 / (cosInnerAngle - cosOuterAngle)
    // SdotL * invAngleRange + (-cosOuterAngle * invAngleRange)
    // SdotL * spotAttenuation.x + spotAttenuation.y

    // If we precompute the terms in a MAD instruction
    half SdotL = dot(spotDirection, lightDirection);
    half atten = saturate(SdotL * spotAttenuation.x + spotAttenuation.y);
    return atten * atten;
}

half4 GetLightDirectionAndAttenuation(LightInput lightInput, float3 positionWS)
{
    half4 directionAndAttenuation;
    float3 posToLightVec = lightInput.position.xyz - positionWS * lightInput.position.w;
    float distanceSqr = max(dot(posToLightVec, posToLightVec), FLT_MIN);

    directionAndAttenuation.xyz = half3(posToLightVec * rsqrt(distanceSqr));
    directionAndAttenuation.w = DistanceAttenuation(distanceSqr, lightInput.distanceAttenuation.xyz);
    directionAndAttenuation.w *= SpotAttenuation(lightInput.spotDirection.xyz, directionAndAttenuation.xyz, lightInput.spotAttenuation);
    return directionAndAttenuation;
}

half4 GetMainLightDirectionAndAttenuation(LightInput lightInput, float3 positionWS)
{
    half4 directionAndAttenuation = lerp(half4(lightInput.position.xyz, 1.0), GetLightDirectionAndAttenuation(lightInput, positionWS), lightInput.position.w);

    // Cookies are only computed for main light
    directionAndAttenuation.w *= CookieAttenuation(positionWS);

    return directionAndAttenuation;
}

///////////////////////////////////////////////////////////////////////////////
//                      Light Abstraction                                    //
///////////////////////////////////////////////////////////////////////////////

Light GetMainLight(float3 positionWS)
{
    LightInput lightInput;
    lightInput.position = _MainLightPosition;
    lightInput.color = _MainLightColor.rgb;
    lightInput.distanceAttenuation = _MainLightDistanceAttenuation;
    lightInput.spotDirection = _MainLightSpotDir;
    lightInput.spotAttenuation = _MainLightSpotAttenuation;

    half4 directionAndRealtimeAttenuation = GetMainLightDirectionAndAttenuation(lightInput, positionWS);

    Light light;
    light.direction = directionAndRealtimeAttenuation.xyz;
    light.attenuation = directionAndRealtimeAttenuation.w;
    light.subtractiveModeAttenuation = lightInput.distanceAttenuation.w;
    light.color = lightInput.color;

    return light;
}

Light GetLight(int i, float3 positionWS)
{
    LightInput lightInput;
    half4 indices = (i < 4) ? unity_4LightIndices0 : unity_4LightIndices1;
    int index = (i < 4) ? i : i - 4;
    int lightIndex = indices[index];
    lightInput.position = _AdditionalLightPosition[lightIndex];
    lightInput.color = _AdditionalLightColor[lightIndex].rgb;
    lightInput.distanceAttenuation = _AdditionalLightDistanceAttenuation[lightIndex];
    lightInput.spotDirection = _AdditionalLightSpotDir[lightIndex];
    lightInput.spotAttenuation = _AdditionalLightSpotAttenuation[lightIndex];

    half4 directionAndRealtimeAttenuation = GetLightDirectionAndAttenuation(lightInput, positionWS);

    Light light;
    light.direction = directionAndRealtimeAttenuation.xyz;
    light.attenuation = directionAndRealtimeAttenuation.w;
    light.subtractiveModeAttenuation = lightInput.distanceAttenuation.w;
    light.color = lightInput.color;

    return light;
}

half GetPixelLightCount()
{
    return min(_AdditionalLightCount.x, unity_LightIndicesOffsetAndCount.y);
}

///////////////////////////////////////////////////////////////////////////////
//                         BRDF Functions                                    //
///////////////////////////////////////////////////////////////////////////////

#define kDieletricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)

struct BRDFData
{
    half3 diffuse;
    half3 specular;
    half perceptualRoughness;
    half roughness;
    half roughness2;
    half grazingTerm;
};

half ReflectivitySpecular(half3 specular)
{
#if (SHADER_TARGET < 30)
    // SM2.0: instruction count limitation
    return specular.r; // Red channel - because most metals are either monocrhome or with redish/yellowish tint
#else
    return max(max(specular.r, specular.g), specular.b);
#endif
}

half OneMinusReflectivityMetallic(half metallic)
{
    // We'll need oneMinusReflectivity, so
    //   1-reflectivity = 1-lerp(dielectricSpec, 1, metallic) = lerp(1-dielectricSpec, 0, metallic)
    // store (1-dielectricSpec) in kDieletricSpec.a, then
    //   1-reflectivity = lerp(alpha, 0, metallic) = alpha + metallic*(0 - alpha) =
    //                  = alpha - metallic * alpha
    half oneMinusDielectricSpec = kDieletricSpec.a;
    return oneMinusDielectricSpec - metallic * oneMinusDielectricSpec;
}

inline void InitializeBRDFData(half3 albedo, half metallic, half3 specular, half smoothness, half alpha, out BRDFData outBRDFData)
{
#ifdef _SPECULAR_SETUP
    half reflectivity = ReflectivitySpecular(specular);
    half oneMinusReflectivity = 1.0 - reflectivity;

    outBRDFData.diffuse = albedo * (half3(1.0h, 1.0h, 1.0h) - specular);
    outBRDFData.specular = specular;
#else

    half oneMinusReflectivity = OneMinusReflectivityMetallic(metallic);
    half reflectivity = 1.0 - oneMinusReflectivity;

    outBRDFData.diffuse = albedo * oneMinusReflectivity;
    outBRDFData.specular = lerp(kDieletricSpec.rgb, albedo, metallic);
#endif

    outBRDFData.grazingTerm = saturate(smoothness + reflectivity);
    outBRDFData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(smoothness);
    outBRDFData.roughness = PerceptualRoughnessToRoughness(outBRDFData.perceptualRoughness);
    outBRDFData.roughness2 = outBRDFData.roughness * outBRDFData.roughness;

#ifdef _ALPHAPREMULTIPLY_ON
    outBRDFData.diffuse *= alpha;
    alpha = alpha * oneMinusReflectivity + reflectivity;
#endif
}


half3 EnvironmentBRDF(BRDFData brdfData, half3 indirectDiffuse, half3 indirectSpecular, half fresnelTerm)
{
    half3 c = indirectDiffuse * brdfData.diffuse;
    float surfaceReduction = 1.0 / (brdfData.roughness2 + 1.0);
    c += surfaceReduction * indirectSpecular * lerp(brdfData.specular, brdfData.grazingTerm, fresnelTerm);
    return c;
}

// Based on Minimalist CookTorrance BRDF
// Implementation is slightly different from original derivation: http://www.thetenthplanet.de/archives/255
//
// * NDF [Modified] GGX
// * Modified Kelemen and Szirmay-​Kalos for Visibility term
// * Fresnel approximated with 1/LdotH
half3 DirectBDRF(BRDFData brdfData, half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS)
{
#ifndef _SPECULARHIGHLIGHTS_OFF
    half3 halfDir = SafeNormalize(lightDirectionWS + viewDirectionWS);

    half NoH = saturate(dot(normalWS, halfDir));
    half LoH = saturate(dot(lightDirectionWS, halfDir));

    // GGX Distribution multiplied by combined approximation of Visibility and Fresnel
    // See "Optimizing PBR for Mobile" from Siggraph 2015 moving mobile graphics course
    // https://community.arm.com/events/1155
    half d = NoH * NoH * (brdfData.roughness2 - 1.h) + 1.00001h;

    half LoH2 = LoH * LoH;
    half specularTerm = brdfData.roughness2 / ((d * d) * max(0.1h, LoH2) * (brdfData.roughness + 0.5h) * 4);

    // on mobiles (where half actually means something) denominator have risk of overflow
    // clamp below was added specifically to "fix" that, but dx compiler (we convert bytecode to metal/gles)
    // sees that specularTerm have only non-negative terms, so it skips max(0,..) in clamp (leaving only min(100,...))
#if defined (SHADER_API_MOBILE)
    specularTerm = specularTerm - HALF_MIN;
    specularTerm = clamp(specularTerm, 0.0, 100.0); // Prevent FP16 overflow on mobiles
#endif

    half3 color = specularTerm * brdfData.specular + brdfData.diffuse;
    return color;
#else
    return brdfData.diffuse;
#endif
}

///////////////////////////////////////////////////////////////////////////////
//                      Global Illumination                                  //
///////////////////////////////////////////////////////////////////////////////

// Samples SH L0, L1 and L2 terms
half3 SampleSH(half3 normalWS)
{
    // LPPV is not supported in Ligthweight Pipeline
    real4 SHCoefficients[7];
    SHCoefficients[0] = unity_SHAr;
    SHCoefficients[1] = unity_SHAg;
    SHCoefficients[2] = unity_SHAb;
    SHCoefficients[3] = unity_SHBr;
    SHCoefficients[4] = unity_SHBg;
    SHCoefficients[5] = unity_SHBb;
    SHCoefficients[6] = unity_SHC;

    return max(half3(0, 0, 0), SampleSH9(SHCoefficients, normalWS));
}

// SH Vertex Evaluation. Depending on target SH sampling might be
// done completely per vertex or mixed with L2 term per vertex and L0, L1
// per pixel. See SampleSHPixel
half3 SampleSHVertex(half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
    return max(half3(0, 0, 0), SampleSH(normalWS));
#elif defined(EVALUATE_SH_MIXED)
    // no max since this is only L2 contribution
    return SHEvalLinearL2(normalWS, unity_SHBr, unity_SHBg, unity_SHBb, unity_SHC);
#endif

    // Fully per-pixel. Nothing to compute.
    return half3(0.0, 0.0, 0.0);
}

// SH Pixel Evaluation. Depending on target SH sampling might be done
// mixed or fully in pixel. See SampleSHVertex
half3 SampleSHPixel(half3 L2Term, half3 normalWS)
{
#ifdef EVALUATE_SH_MIXED
    half3 L0L1Term = SHEvalLinearL0L1(normalWS, unity_SHAr, unity_SHAg, unity_SHAb);
    return max(half3(0, 0, 0), L2Term + L0L1Term);
#endif

    // Default: Evaluate SH fully per-pixel
    return SampleSH(normalWS);
}

// Sample baked lightmap. Non-Direction and Directional if available.
// Realtime GI is not supported.
half3 SampleLightmap(float2 lightmapUV, half3 normalWS)
{
#ifdef UNITY_LIGHTMAP_FULL_HDR
    bool encodedLightmap = false;
#else
    bool encodedLightmap = true;
#endif

    // The shader library sample lightmap functions transform the lightmap uv coords to apply bias and scale.
    // However, lightweight pipeline already transformed those coords in vertex. We pass half4(1, 1, 0, 0) and
    // the compiler will optimize the transform away.
    half4 transformCoords = half4(1, 1, 0, 0);

#ifdef DIRLIGHTMAP_COMBINED
    return SampleDirectionalLightmap(TEXTURE2D_PARAM(unity_Lightmap, samplerunity_Lightmap),
        TEXTURE2D_PARAM(unity_LightmapInd, samplerunity_Lightmap),
        lightmapUV, transformCoords, normalWS, encodedLightmap, unity_Lightmap_HDR);
#else
    return SampleSingleLightmap(TEXTURE2D_PARAM(unity_Lightmap, samplerunity_Lightmap), lightmapUV, transformCoords, encodedLightmap, unity_Lightmap_HDR);
#endif
}

// We either sample GI from baked lightmap or from probes.
// If lightmap: sampleData.xy = lightmapUV
// If probe: sampleData.xyz = L2 SH terms
half3 SampleGI(float4 sampleData, half3 normalWS)
{
#ifdef LIGHTMAP_ON
    return SampleLightmap(sampleData.xy, normalWS);
#endif

    // If lightmap is not enabled we sample GI from SH
    return SampleSHPixel(sampleData.xyz, normalWS);
}

half3 GlossyEnvironmentReflection(half3 reflectVector, half perceptualRoughness, half occlusion)
{
#if !defined(_GLOSSYREFLECTIONS_OFF)
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip);

#if !defined(UNITY_USE_NATIVE_HDR)
    half3 irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#else
    half3 irradiance = encodedIrradiance.rbg;
#endif

    return irradiance * occlusion;
#endif // GLOSSY_REFLECTIONS

    return _GlossyEnvironmentColor.rgb * occlusion;
}

half3 GlobalIllumination(BRDFData brdfData, half3 bakedGI, half occlusion, half3 normalWS, half3 viewDirectionWS)
{
    half3 reflectVector = reflect(-viewDirectionWS, normalWS);
    half fresnelTerm = Pow4(1.0 - saturate(dot(normalWS, viewDirectionWS)));

    half3 indirectDiffuse = bakedGI * occlusion;
    half3 indirectSpecular = GlossyEnvironmentReflection(reflectVector, brdfData.perceptualRoughness, occlusion);

    return EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);
}

half3 SubtractDirectMainLightFromLightmap(Light mainLight, half3 normalWS, half3 bakedGI)
{
    // Let's try to make realtime shadows work on a surface, which already contains
    // baked lighting and shadowing from the main sun light.
    // Summary:
    // 1) Calculate possible value in the shadow by subtracting estimated light contribution from the places occluded by realtime shadow:
    //      a) preserves other baked lights and light bounces
    //      b) eliminates shadows on the geometry facing away from the light
    // 2) Clamp against user defined ShadowColor.
    // 3) Pick original lightmap value, if it is the darkest one.


    // 1) Gives good estimate of illumination as if light would've been shadowed during the bake.
    //    Preserves bounce and other baked lights
    //    No shadows on the geometry facing away from the light
    half shadowStrength = GetShadowStrength();
    half NdotL = saturate(dot(mainLight.direction, normalWS));
    half3 lambert = mainLight.color * NdotL;
    half3 estimatedLightContributionMaskedByInverseOfShadow = lambert * (1.0 - mainLight.attenuation);
    half3 subtractedLightmap = bakedGI - estimatedLightContributionMaskedByInverseOfShadow;

    // 2) Allows user to define overall ambient of the scene and control situation when realtime shadow becomes too dark.
    half3 realtimeShadow = max(subtractedLightmap, _SubtractiveShadowColor.xyz);
    realtimeShadow = lerp(bakedGI, realtimeShadow, shadowStrength);

    // 3) Pick darkest color
    return min(bakedGI, realtimeShadow);
}

void MixRealtimeAndBakedGI(inout Light light, half3 normalWS, inout half3 bakedGI, half4 shadowMask)
{
#if defined(_MIXED_LIGHTING_SUBTRACTIVE) && defined(LIGHTMAP_ON) && defined(_SHADOWS_ENABLED)
    bakedGI = lerp(SubtractDirectMainLightFromLightmap(light, normalWS, bakedGI), bakedGI, _MainLightPosition.w);
#endif

#if defined(LIGHTMAP_ON)
    #if defined(_MIXED_LIGHTING_SHADOWMASK)
        // TODO:
    #elif defined(_MIXED_LIGHTING_SUBTRACTIVE)
        // Subtractive Light mode has direct light contribution baked into lightmap for mixed lights.
        // We need to remove direct realtime contribution from mixed lights
        // subtractiveModeBakedOcclusion is set 0.0 if this light occlusion was baked in the lightmap, 1.0 otherwise.
        light.attenuation *= light.subtractiveModeAttenuation;
    #endif
#endif
}

///////////////////////////////////////////////////////////////////////////////
//                      Lighting Functions                                   //
///////////////////////////////////////////////////////////////////////////////
half3 LightingLambert(half3 lightColor, half3 lightDir, half3 normal)
{
    half NdotL = saturate(dot(normal, lightDir));
    return lightColor * NdotL;
}

half3 LightingSpecular(half3 lightColor, half3 lightDir, half3 normal, half3 viewDir, half4 specularGloss, half shininess)
{
    half3 halfVec = SafeNormalize(lightDir + viewDir);
    half NdotH = saturate(dot(normal, halfVec));
    half3 specularReflection = specularGloss.rgb * pow(NdotH, shininess) * specularGloss.a;
    return lightColor * specularReflection;
}

half3 LightingPhysicallyBased(BRDFData brdfData, half3 lightColor, half3 lightDirectionWS, half lightAttenuation, half3 normalWS, half3 viewDirectionWS)
{
    half NdotL = saturate(dot(normalWS, lightDirectionWS));
    half3 radiance = lightColor * (lightAttenuation * NdotL);
    return DirectBDRF(brdfData, normalWS, lightDirectionWS, viewDirectionWS) * radiance;
}

half3 LightingPhysicallyBased(BRDFData brdfData, Light light, half3 normalWS, half3 viewDirectionWS)
{
    return LightingPhysicallyBased(brdfData, light.color, light.direction, light.attenuation, normalWS, viewDirectionWS);
}

half3 VertexLighting(float3 positionWS, half3 normalWS)
{
    half3 vertexLightColor = half3(0.0, 0.0, 0.0);

#if defined(_VERTEX_LIGHTS)
    int vertexLightStart = _AdditionalLightCount.x;
    int vertexLightEnd = min(_AdditionalLightCount.y, unity_LightIndicesOffsetAndCount.y);
    for (int lightIter = vertexLightStart; lightIter < vertexLightEnd; ++lightIter)
    {
        Light light = GetLight(lightIter, positionWS);

        half3 lightColor = light.color * light.attenuation;
        vertexLightColor += LightingLambert(lightColor, light.direction, normalWS);
    }
#endif

    return vertexLightColor;
}

#define ALPHA_R   -5.0
#define ALPHA_TT  ALPHA_R / 2.0
#define ALPHA_TRT -3.0 * ALPHA_R / 2.0

#define BETA_R    5.0
#define BETA_TT   BETA_R / 2.0
#define BETA_TRT  2.0 * BETA_R

#define IOR 1.55

float Fresnel(float ior, float x)
{
    float num = 1.0 - ior;
    float den = 1.0 + ior;
    float F0 = (num * num) / (den * den);

    return F0 + (1.0 - F0) * pow(1.0 - x, 5);
}

//M Term is a simple gaussian distribution
float M(float B, float Theta)
{
    float term0 = 1.0 / (B * sqrt(2.0 * PI));
    float term1 = -( (Theta * Theta) / (2.0 * B * B) );
    return term0 * exp(term1);
}

//NR Term
float NR(float CosPhi, float CosHalfPhi)
{
    float Distribution = 0.25 * CosHalfPhi;
    float Attenuation  = Fresnel(IOR, CosHalfPhi);
    return Distribution * Attenuation;
}

//NTT Term
float3 NTT(float CosPhi, float CosHalfPhi, float CosThetaD, float3 VolumeAlbedo)
{
    //Assumes Eta of 1.55 for human hair.
    float EtaPrime = (1.19 / CosThetaD) + 0.36 * CosThetaD;

    float a = 1.0 / EtaPrime;
    float h = (1.0 + (a * (0.6 - (0.8 * CosPhi)))) * CosHalfPhi;

    //Attenuation Term
    float F = Fresnel(EtaPrime, CosThetaD * sqrt(1.0 - h*h));
    float Fp = Fresnel(IOR, CosHalfPhi);

    float Texp = (sqrt(1.0 - (h*h*a*a)) / (2.0 * CosThetaD));
    float3 T = pow(VolumeAlbedo, Texp);

    float3 A = pow(1 - F, 2) * Fp * T;

    //Distribution Term
    float D = exp((-3.65 * CosPhi) - 3.98);

    return A * D;
}

//NTRT Term
float3 NTRT(float CosPhi, float CosHalfPhi, float CosThetaD, float3 VolumeAlbedo)
{
    //Assumes Eta of 1.55 for human hair.
    float EtaPrime = (1.19 / CosThetaD) + 0.36 * CosThetaD;

    float h = sqrt(3) / 2.0;
    float F = Fresnel(EtaPrime, CosThetaD * sqrt(1.0 - h*h));
    float Fp = Fresnel(IOR, CosHalfPhi);
    float3 T = pow(VolumeAlbedo, 0.8 / CosThetaD);

    float3 A = pow(1 - F, 2) * Fp * T;
    float D = exp((17.0 * CosPhi) - 16.78);

    return A * D;
}

half3 Hair(BRDFData brdfData,
           half3 Light, half3 View, half3 Normal, half3 Tangent)
{
    //Calculate Binormal to complete the onormal basis.
    half3 Binormal = cross(Tangent, Normal); 

    //Calculate cosines.
    float TdotL = dot(Tangent,         Light);
    float TdotV = dot(Tangent,         View);
    float BdotL = dot(Binormal,        Light);
    float BdotV = dot(Binormal,        View);
    float LdotV = dot(Light, View);

    //Azimuth projection.
    float3 ProjLight = Light - TdotL * Tangent;
    float3 ProjView  = View  - TdotV * Tangent;

    float ThetaH = (TdotL + TdotV) / 2.0;

    float CosPhi     = dot(ProjView, ProjLight) * pow(dot(ProjView, ProjView) * dot(ProjLight, ProjLight), -0.5);
    float CosHalfPhi = sqrt(0.5 + 0.5 * CosPhi);
    float CosThetaD  = cos( (acos(TdotV) - acos(TdotL)) / 2.0 );

    //R Path
    float mr    = M(radians(BETA_R),   ThetaH - radians(ALPHA_R));
    float nr    = NR(CosPhi, CosHalfPhi);
    
    //TT Path
    float mtt   = M(radians(BETA_TT),  ThetaH - radians(ALPHA_TT));
    float3 ntt  = NTT(CosPhi, CosHalfPhi, CosThetaD, brdfData.diffuse);

    //TRT Path
    float mtrt  = M(radians(BETA_TRT), ThetaH - radians(ALPHA_TRT));
    float3 ntrt = NTRT(CosPhi, CosHalfPhi, CosThetaD, brdfData.diffuse);

    return brdfData.diffuse + (1.5 * ((mr * nr * 1) + (mtt * ntt * 1) + (mtrt * ntrt * 5)) / (CosThetaD * CosThetaD));
}

half3 HairGlobalIllumination(BRDFData brdfData, half3 bakedGI, half occlusion, half3 normalWS, half3 viewDirectionWS,
                             half3 tangent)
{
    half3 reflectVector = normalWS;// reflect(-viewDirectionWS, normalWS);
    half fresnelTerm = Pow4(1.0 - saturate(dot(normalWS, viewDirectionWS)));

    half3 indirectDiffuse = bakedGI * occlusion;
    half3 indirectSpecular = GlossyEnvironmentReflection(reflectVector, brdfData.perceptualRoughness, occlusion);
    
    float TdotL = dot(tangent, normalWS);
    float TdotV = dot(tangent, viewDirectionWS);
    float ThetaH = (TdotL + TdotV) / 1.0;
    float mr    = M(radians(BETA_R),   ThetaH - radians(ALPHA_R));

    return EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);
}

///////////////////////////////////////////////////////////////////////////////
//                      Fragment Functions                                   //
//       Used by ShaderGraph and others builtin renderers                    //
///////////////////////////////////////////////////////////////////////////////
half4 LightweightFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha, half3 tangent)
{
    BRDFData brdfData;
    InitializeBRDFData(albedo, metallic, specular, smoothness, alpha, brdfData);

    Light mainLight = GetMainLight(inputData.positionWS);
    mainLight.attenuation *= RealtimeShadowAttenuation(inputData.shadowCoord);

    float3 V = inputData.viewDirectionWS;
    float3 T = tangent;
    float3 normalFake = normalize(V - T * dot(T, V));

    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));
    half3 color = HairGlobalIllumination(brdfData, inputData.bakedGI, occlusion, normalFake, inputData.viewDirectionWS, tangent);
    
    //Hair Shading.
    half NdotL = saturate(dot(inputData.normalWS, mainLight.direction));
    half3 radiance = mainLight.color * (mainLight.attenuation * NdotL);
    color += Hair(brdfData, mainLight.direction, inputData.viewDirectionWS, inputData.normalWS, tangent) * radiance;

    
#ifdef _ADDITIONAL_LIGHTS
    int pixelLightCount = GetPixelLightCount();
    for (int i = 0; i < pixelLightCount; ++i)
    {
        Light light = GetLight(i, inputData.positionWS);

        half NdotL = saturate(dot(inputData.normalWS, light.direction));
        radiance = light.color * (light.attenuation * NdotL);
        color += Hair(brdfData, light.direction, inputData.viewDirectionWS, inputData.normalWS, tangent) * radiance;
    }
#endif
    

    color += inputData.vertexLighting * brdfData.diffuse;
    color += emission;
    
    return half4(color, alpha);
}

half4 LightweightFragmentBlinnPhong(InputData inputData, half3 diffuse, half4 specularGloss, half shininess, half3 emission, half alpha)
{
    Light mainLight = GetMainLight(inputData.positionWS);
    mainLight.attenuation *= RealtimeShadowAttenuation(inputData.shadowCoord);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));

    half3 attenuatedLightColor = mainLight.color * mainLight.attenuation;
    half3 diffuseColor = inputData.bakedGI + LightingLambert(attenuatedLightColor, mainLight.direction, inputData.normalWS);
    half3 specularColor = LightingSpecular(attenuatedLightColor, mainLight.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, shininess);

#ifdef _ADDITIONAL_LIGHTS
    int pixelLightCount = GetPixelLightCount();
    for (int i = 0; i < pixelLightCount; ++i)
    {
        Light light = GetLight(i, inputData.positionWS);
        half3 attenuatedLightColor = light.color * light.attenuation;
        diffuseColor += LightingLambert(attenuatedLightColor, light.direction, inputData.normalWS);
        specularColor += LightingSpecular(attenuatedLightColor, light.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, shininess);
    }
#endif

    half3 finalColor = diffuseColor * diffuse + emission;
    finalColor += inputData.vertexLighting * diffuse;
    
#if defined(_SPECGLOSSMAP) || defined(_SPECULAR_COLOR)
    finalColor += specularColor;
#endif

    ApplyFog(finalColor, inputData.fogCoord);
    return half4(finalColor, alpha);
}
#endif