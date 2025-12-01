
from django.shortcuts import render, get_object_or_404, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.db.models import Q
from .models import Course, Review

def home(request):
    query = request.GET.get('q', '')
    courses = Course.objects.all().order_by('-created_at')
    
    if query:
        courses = courses.filter(
            Q(title__icontains=query) | 
            Q(description__icontains=query)
        )
        
    return render(request, 'home.html', {'courses': courses})

def course_detail(request, pk):
    course = get_object_or_404(Course, pk=pk)
    return render(request, 'course_detail.html', {'course': course})

@login_required
def add_review(request, pk):
    course = get_object_or_404(Course, pk=pk)
    if request.method == 'POST':
        rating = request.POST.get('rating')
        text = request.POST.get('text')
        
        Review.objects.create(
            course=course,
            author=request.user,
            rating=rating,
            text=text
        )
        messages.success(request, 'Review posted!')
        
    return redirect('course_detail', pk=pk)
