# Design Document

## Overview

This design outlines the enhancement of the Butterfly route service documentation to create a comprehensive, visually appealing guide that showcases the authentication-aware routing capabilities. The documentation will follow the Invertase.io framework patterns while maintaining consistency with Butterfly's philosophy of removability and developer-friendly design.

## Architecture

### Documentation Structure

The enhanced route service documentation will be organized into the following main sections:

1. **Hero Section** - Clear value proposition and key benefits
2. **Quick Start Guide** - Minimal setup for immediate results
3. **Core Concepts** - Fundamental routing principles
4. **Authentication Flow** - Detailed auth-aware routing explanation
5. **API Reference** - Complete method and property documentation
6. **Advanced Usage** - Complex scenarios and customization
7. **Migration & Removal** - Butterfly's removability promise
8. **Troubleshooting** - Common issues and solutions

### Visual Flow Diagram

A Butterfly-style sequence diagram titled "How the Butterfly Route Service Works" will illustrate:

```
User Request → Route Evaluation → Auth Check → Decision Tree → Final Navigation
```

The diagram will show the complete decision flow including:
- Initial route declaration (initialRoute)
- Generated routes integration
- Authentication state evaluation
- Public route checking
- Auth trigger route handling
- Temporary redirect storage
- Debug route bypass
- Final navigation decision

## Components and Interfaces

### Documentation Components

#### 1. Enhanced Code Examples
- **Basic Setup**: Simple GoRouterService extension
- **Auth Integration**: GoRouterAuthRoute implementation
- **Configuration**: Complete service setup with all getters
- **Advanced Patterns**: Custom redirect logic and role-based routing

#### 2. Interactive Elements
- **Configuration Builder**: Step-by-step setup guide
- **Flow Visualizer**: Interactive routing decision tree

#### 3. Removability Approach
- **Special Note Section**: Explanation of why traditional side-by-side comparison isn't applicable
- **Alternative Removal Guide**: Instructions for extracting redirect logic from GoRouterService
- **Manual Implementation**: Guide for implementing equivalent functionality in native Go Router

#### 4. Reference Sections
- **API Documentation**: All methods, properties, and their signatures
- **Configuration Options**: Complete list of available getters and their purposes
- **Integration Guides**: How to work with other Butterfly services

### Content Architecture

#### Core Service Types
1. **BaseRouteService** - Foundation routing service
2. **GoRouterService** - Go Router implementation
3. **GoRouterAuthRoute** - Authentication-aware routing

#### Key Configuration Points
- `initialRoute` - Default entry point
- `routes` - Route definitions (typically from go_router generator)
- `publicRoutes` - Routes accessible without authentication
- `authTriggerRoutes` - Routes that trigger auth flow (defaults to signInRoutePath)
- `defaultAuthRoute` - Post-authentication destination
- `signInRoutePath` - Login page route
- `signUpRoutePath` - Registration page route
- `redirectOverride` - One-time redirect bypass
- `temporaryRedirect` - Deep link storage during auth flow
- `debugRoutes` - Development bypass routes

## Data Models

### Documentation Content Model

```typescript
interface RouteServiceDoc {
  sections: {
    hero: HeroSection;
    quickStart: QuickStartSection;
    concepts: ConceptsSection;
    authFlow: AuthFlowSection;
    apiReference: APIReferenceSection;
    advanced: AdvancedSection;
    migration: MigrationSection;
    troubleshooting: TroubleshootingSection;
  };
  diagram: SequenceDiagram;
  codeExamples: CodeExample[];
  comparisons: ComparisonTab[];
}
```

### Code Example Structure

```typescript
interface CodeExample {
  title: string;
  description: string;
  code: string;
  language: 'dart';
  category: 'basic' | 'auth' | 'advanced' | 'migration';
  showComparison?: boolean;
  nativeAlternative?: string;
}
```

### Routing Flow Model

```typescript
interface RoutingFlow {
  steps: FlowStep[];
  decisionPoints: DecisionPoint[];
  outcomes: NavigationOutcome[];
}

interface FlowStep {
  id: string;
  title: string;
  description: string;
  codeReference?: string;
  nextSteps: string[];
}
```

## Error Handling

### Documentation Error Prevention

1. **Code Validation**: All code examples must be syntactically correct and runnable
2. **Link Verification**: Internal and external links must be validated
3. **Version Compatibility**: Examples must work with current package versions
4. **Cross-Reference Integrity**: API references must match actual implementation

### User Experience Error Handling

1. **Progressive Disclosure**: Complex topics introduced gradually
2. **Clear Prerequisites**: Each section states required knowledge/setup
3. **Fallback Examples**: Alternative approaches when primary method fails
4. **Recovery Paths**: Clear guidance when things go wrong

## Testing Strategy

### Content Testing

1. **Code Example Validation**
   - All Dart code examples compile successfully
   - Examples run without errors in test environment
   - Generated output matches expected behavior

2. **Documentation Accuracy**
   - API references match actual implementation
   - Configuration options are current and complete
   - Flow diagrams accurately represent code behavior

3. **User Journey Testing**
   - New developers can follow quick start successfully
   - Experienced developers find advanced topics easily
   - Migration paths are clear and complete

### Visual Testing

1. **Diagram Accuracy**
   - Sequence diagram matches actual routing flow
   - Decision points reflect real code logic
   - Visual elements enhance understanding

2. **Responsive Design**
   - Documentation renders correctly on all devices
   - Code blocks remain readable on mobile
   - Diagrams scale appropriately

### Integration Testing

1. **Navigation Structure**
   - All internal links work correctly
   - Sidebar navigation reflects content hierarchy
   - Search functionality finds relevant content

2. **Framework Integration**
   - Invertase.io framework features work correctly
   - Styling matches Butterfly brand guidelines
   - Interactive elements function as expected

## Implementation Approach

### Phase 1: Content Enhancement
- Rewrite existing sections with improved clarity
- Add missing configuration options and examples
- Create comprehensive API reference

### Phase 2: Visual Enhancement
- Design and implement routing flow diagram
- Add comparison tabs for Butterfly vs native approaches
- Enhance code examples with better formatting and context

### Phase 3: Advanced Features
- Create interactive configuration builder
- Add troubleshooting decision tree
- Implement advanced usage patterns and examples

### Phase 4: Integration & Polish
- Integrate with existing Butterfly documentation structure
- Ensure consistent styling and navigation
- Validate all links and references

## Success Metrics

### Developer Experience
- Reduced time to implement basic routing (target: <10 minutes)
- Decreased support questions about routing configuration
- Increased adoption of authentication features

### Documentation Quality
- All code examples compile and run successfully
- Zero broken internal links
- Complete API coverage with examples

### Maintainability
- Documentation updates require minimal effort
- New features can be documented using established patterns
- Content remains accurate across package updates